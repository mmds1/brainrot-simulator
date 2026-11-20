-- Simulador de lutas 3x3 (Brainrot Fighter). Gerado por tools/battlesim/build_site: não editar à mão.
local SOURCES = {}
SOURCES["src/server/Combat/ArenaEngine.luau"] = [=[
--[[
	ArenaEngine — a luta do evento Arena: 4 times de até 3 brainrots, cada um por si (Config/ArenaBattleConfig,
	Shared/Events/ArenaBattleLayout; pedido do usuário, 08/11/2026).

		ArenaEngine.run(teams, { Seed = n? }) → roteiro { Version, Seed, Mode = "ArenaBattle", Units, Events, Result }
		teams = { { Side = "A", Slots = { [1|2|3] = UnitSpec } }, ... }   (slot vazio = ninguém ali)

	As regras de golpe são as da Torre (BattleEngine.Core: passivas, crítico, esquiva, espinhos, escudo...). O que muda:
	  - Tempo em SEGUNDOS do "mundo": ataques por segundo em linha reta pela Velocidade atual (CombatConfig.RealtimeAttack:
	    500 → 1/s, 2500 → 1,8/s, +0,2/s a cada 500; lentidão e SpdUp mudam a Velocidade, 13/11/2026), e os
	    golpes de um mesmo turno saem com StrikeGap entre eles (as pancadas do Tung seguem as animações: ComboTiming).
	    Cada evento ganha At. O Za Warudo para o mundo: os golpes dele têm o At do "TimeStop" e StopAt (s dentro da
	    parada), e o "TimeStop" tem Duration (o cliente congela o resto por esse tempo).
	  - Posição: cada brainrot ocupa um lugar de Layout.Points ("Move" = { U, To, At, Arrive }). No começo todos andam
	    até o lugar do par (o meio do caminho) com o alvo marcado (Layout.opponent). Ninguém apanha andando.
	  - Alvo: o marcado enquanto estiver colado (AttackRange). Se cair (ou sair de perto): inimigo colado → bate nele
	    sem andar; inimigo vindo para perto → espera; senão vai para a vaga livre mais perto dele que fica colada no
	    inimigo mais perto (reservada na hora: ninguém mais vai para lá).
	  - Troca de alvo: quem leva SwitchAfterHits golpes de alguém que não é o alvo dele, com MENOS Vida atual que o alvo,
	    passa a bater nele (se estiver colado; provoke, 15/11/2026)
	  - Golpe em área pega os inimigos até AreaRadius de quem bate; o enfraquecimento do início, quem vai lutar perto.
	Fim: um time de pé (ou nenhum) ou MaxSeconds (vence quem tem a maior fração de Vida). Result.Placement = os times
	do 1º ao último (quem caiu depois fica na frente).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local ArenaBattleConfig = require(Shared.Config.ArenaBattleConfig)
local CombatConfig = require(Shared.Config.CombatConfig)
local ComboTiming = require(Shared.Brainrot.ComboTiming)
local Layout = require(Shared.Events.ArenaBattleLayout)
local BattleEngine = require(script.Parent.BattleEngine)

local core = BattleEngine.Core
local config = ArenaBattleConfig

local SCRIPT_VERSION = 1
local MAX_STEPS = 20000 -- trava de segurança do laço
local STRIKES = { Attack = true, Blow = true, Extra = true, Counter = true }

export type TeamInput = { Side: string, Slots: { [number]: BattleEngine.UnitSpec } }

local ArenaEngine = {}

local function round2(value: number): number
	return math.floor(value * 100 + 0.5) / 100
end

local function flatDistance(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

function ArenaEngine.run(teams: { TeamInput }, options: { Seed: number? }): { [string]: any }
	local seed = options.Seed or Random.new():NextInteger(1, 2 ^ 31 - 1)
	local state: { [string]: any } = {
		rng = Random.new(seed),
		units = {},
		sides = {},
		events = {},
		turns = 0,
		tieSide = nil,
		-- "1 turno" = TurnSeconds segundos do mundo (durações e efeitos por turno; BattleEngine)
		turnSeconds = config.TurnSeconds,
	}
	local info: { [string]: { [string]: any } } = {}
	local byKey: { [string]: any } = {}
	local holder: { [number]: any } = {} -- lugar → quem está nele (ou indo para ele)
	local eliminatedAt: { [string]: number } = {}
	local order: { string } = {}

	-- Relógio: clock = hora do mundo do que está acontecendo; cursor = segundos dentro do turno atual
	local clock, cursor, strikes, comboBase = 0, 0, 0, 0
	-- Velocidade de ataque do turno (19/11/2026, pedido do usuário): até 1 ataque/s = 1; acima disso, os tempos dos
	-- golpes do turno (pancadas do padrão, StrikeGap e RecoverTime) encolhem na mesma proporção, junto com as animações
	-- (o cliente acelera pelo Rate do evento, ArenaBattleController Ranked.animRate)
	local turnRate = 1
	local stopEvent: { [string]: any }? = nil
	local stopCursor, stopStrikes, totalStop = 0, 0, 0
	local lastAt = 0

	---------------------------------------------------------------- brainrots

	for _, team in teams do
		table.insert(order, team.Side)
		state.sides[team.Side] = {}
		for slot = 1, 3 do
			local spec = team.Slots[slot]
			if spec then
				local unit = core.makeUnit(spec, team.Side, slot)
				-- Ataques por segundo em linha reta pela Velocidade ATUAL (já com lentidão e bônus de velocidade)
				unit.IntervalOf = CombatConfig.attackInterval
				-- Vida da Arena (HpMultiplier): a luta dura mais, igual para todos
				unit.MaxHp = math.max(1, math.floor(unit.MaxHp * config.HpMultiplier + 0.5))
				unit.Hp = math.max(1, math.floor(unit.Hp * config.HpMultiplier + 0.5))
				unit.Slot = slot
				unit.Species = spec.Species
				unit.Pos3 = Layout.formation(team.Side, slot)
				unit.Point = nil
				unit.Target = nil
				unit.MovingUntil = 0
				unit.ThinkAt = nil
				table.insert(state.sides[team.Side], unit)
				table.insert(state.units, unit)
				byKey[unit.Key] = unit
				info[unit.Key] = {
					Side = team.Side,
					Slot = slot,
					Species = spec.Species,
					Passive = unit.PassiveId,
					PassiveName = unit.PassiveName,
					Level = spec.Level,
					Stars = spec.Stars,
					Mutation = spec.Mutation, -- Dourado (19/11/2026)
					MaxHp = unit.MaxHp,
					Hp = unit.Hp,
					Atk = unit.Atk,
					Spd = unit.Spd,
					Scale = spec.Scale or 1,
					Size = spec.Size, -- % de tamanho (balão de stats; 13/11/2026)
				}
			end
		end
	end

	local function settled(unit: any): boolean
		return unit.MovingUntil <= clock + cursor + 1e-6
	end

	local function sideAlive(side: string): boolean
		for _, unit in state.sides[side] do
			if unit.Alive then
				return true
			end
		end
		return false
	end

	local function aliveSides(): number
		local alive = 0
		for _, side in order do
			if sideAlive(side) then
				alive += 1
			end
		end
		return alive
	end

	local function hpShare(side: string): number
		local hp, max = 0, 0
		for _, unit in state.sides[side] do
			max += unit.MaxHp
			if unit.Alive then
				hp += unit.Hp
			end
		end
		return if max > 0 then hp / max else 0
	end

	-- Inimigos colados nele (de pé e parados no lugar): o mais perto primeiro; empate → o mais machucado
	local function adjacent(unit: any): { any }
		local list = {}
		for _, other in state.units do
			if
				other.Side ~= unit.Side
				and other.Alive
				and settled(other)
				and flatDistance(unit.Pos3, other.Pos3) <= config.AttackRange
			then
				table.insert(list, other)
			end
		end
		table.sort(list, function(a, b)
			local distanceA, distanceB = flatDistance(unit.Pos3, a.Pos3), flatDistance(unit.Pos3, b.Pos3)
			if math.abs(distanceA - distanceB) > 0.01 then
				return distanceA < distanceB
			end
			local shareA, shareB = a.Hp / a.MaxHp, b.Hp / b.MaxHp
			if math.abs(shareA - shareB) > 1e-6 then
				return shareA < shareB
			end
			return a.Key < b.Key
		end)
		return list
	end

	---------------------------------------------------------------- ganchos do motor

	state.now = function(): number
		return clock + cursor
	end
	-- Morte súbita (config.Overtime): aos Start s o dano de todos × (1 + Bonus), e mais Bonus a cada Every s
	local overtime = config.Overtime
	local function overtimeLevel(at: number): number
		if at < overtime.Start then
			return 0
		end
		return math.floor((at - overtime.Start) / overtime.Every) + 1
	end
	state.damageBonus = function(): number
		return 1 + overtimeLevel(clock + cursor) * overtime.Bonus
	end

	-- Troca de alvo (15/11/2026, pedido do usuário): conta os golpes que cada um leva de quem NÃO é o alvo dele; no
	-- SwitchAfterHits-ésimo, se quem bate tem menos Vida atual que o alvo e está colado, vira o alvo novo
	local function provoke(event: { [string]: any })
		local attacker, victim = byKey[event.U], byKey[event.Target]
		if not attacker or not victim or attacker == victim or not attacker.Alive or not victim.Alive then
			return
		end
		local focus = victim.Target
		if focus == attacker then
			victim.Provoked = nil
			return
		end
		victim.Provoked = victim.Provoked or {}
		local count = (victim.Provoked[attacker.Key] or 0) + 1
		victim.Provoked[attacker.Key] = count
		if
			count >= config.SwitchAfterHits
			and focus
			and focus.Alive
			and attacker.Hp < focus.Hp
			and settled(attacker)
			and flatDistance(victim.Pos3, attacker.Pos3) <= config.AttackRange
		then
			victim.Target = attacker
			victim.Provoked = nil
		end
	end

	-- Carimba a hora de cada evento (ver o cabeçalho); "Turn" não vai para o roteiro
	state.stamp = function(event: { [string]: any }): boolean?
		local kind = event.T
		if kind == "Turn" then
			return false
		end
		if STRIKES[kind] and event.Target then
			provoke(event)
		end
		if kind == "Overtime" then
			return true -- a hora vem pronta (a do degrau)
		end
		if kind == "TimeStop" then
			event.At = round2(clock + cursor)
			stopEvent, stopCursor, stopStrikes = event, config.TimeStop.Intro, 0
			return true
		end
		local stop = stopEvent
		if kind == "TimeResume" and stop then
			stop.Duration = round2(stopCursor + config.TimeStop.Outro)
			event.At = stop.At
			event.StopAt = round2(stopCursor)
			totalStop += stop.Duration
			stopEvent = nil
			return true
		end
		local counted = STRIKES[kind] and not (event.All and not event.FxFirst)
		if stop then
			if counted then
				if stopStrikes > 0 then
					stopCursor += config.TimeStop.Gap
				end
				stopStrikes += 1
			end
			event.At = stop.At
			event.StopAt = round2(stopCursor)
			return true
		end
		if counted then
			turnRate = math.max(turnRate, tonumber(event.Rate) or 1)
			if kind == "Blow" then
				-- Pancadas seguidas do padrão (Tung): no ritmo das animações de golpe do modelo
				local unit = byKey[event.U]
				local offset = ComboTiming.offset(unit and unit.Species or "", event.Hit or 2)
				cursor = math.max(cursor + 0.05, comboBase + offset / turnRate)
			elseif strikes > 0 then
				cursor += (config.StrikeGap[kind] or 0.4) / turnRate
			end
			if kind == "Attack" then
				comboBase = cursor
			end
			strikes += 1
		end
		event.At = round2(clock + cursor)
		lastAt = math.max(lastAt, event.At)
		return true
	end

	state.targetOf = function(unit: any): any?
		local target = unit.Target
		if
			target
			and target.Alive
			and settled(target)
			and flatDistance(unit.Pos3, target.Pos3) <= config.AttackRange
		then
			return target
		end
		local list = adjacent(unit)
		unit.Target = list[1]
		return list[1]
	end

	state.areaOf = function(unit: any): { any }
		local found = {}
		for _, other in state.units do
			if
				other.Side ~= unit.Side
				and other.Alive
				and settled(other)
				and flatDistance(unit.Pos3, other.Pos3) <= config.AreaRadius
			then
				table.insert(found, other)
			end
		end
		return found
	end

	-- Enfraquecimento do início (Gravidade): quem vai lutar perto dele (pelos lugares do começo)
	state.startFoes = function(unit: any): { any }
		local mine = Layout.Points[Layout.fightPoint(unit.Side, unit.Slot)]
		local found = {}
		for _, other in state.units do
			local theirs = Layout.Points[Layout.fightPoint(other.Side, other.Slot)]
			if other.Side ~= unit.Side and flatDistance(mine, theirs) <= config.AreaRadius then
				table.insert(found, other)
			end
		end
		return found
	end

	state.onDeath = function(unit: any)
		if unit.Point and holder[unit.Point] == unit then
			holder[unit.Point] = nil
		end
		local now = clock + cursor
		for _, other in state.units do
			if other.Target == unit then
				other.Target = nil
				if other.Alive and settled(other) then
					other.ThinkAt = math.min(other.ThinkAt or math.huge, now + config.ReactionTime)
				end
			end
		end
		if not sideAlive(unit.Side) and not eliminatedAt[unit.Side] then
			eliminatedAt[unit.Side] = now
		end
	end

	---------------------------------------------------------------- andar e decidir

	local function moveTo(unit: any, index: number)
		if unit.Point and holder[unit.Point] == unit then
			holder[unit.Point] = nil
		end
		holder[index] = unit
		unit.Point = index
		local destination = Layout.Points[index]
		local start = clock + cursor
		local arrive = start + flatDistance(unit.Pos3, destination) / config.WalkSpeed
		unit.Pos3 = destination
		unit.MovingUntil = arrive
		unit.Next = math.max(unit.Next, arrive + config.SettleTime)
		core.emit(state, { T = "Move", U = unit.Key, To = index, Arrive = round2(arrive) })
	end

	-- "attack" (alvo colado), "wait", hora (alguém vem para perto, ou não há vaga), "move", lugar
	local function decide(unit: any): (string, number?)
		local now = clock + cursor
		local close = adjacent(unit)
		if close[1] then
			unit.Target = close[1]
			return "attack", nil
		end
		-- Inimigo andando para um lugar colado nele: espera ele chegar
		local coming, soonest = nil, math.huge
		for _, other in state.units do
			if
				other.Side ~= unit.Side
				and other.Alive
				and not settled(other)
				and flatDistance(other.Pos3, unit.Pos3) <= config.AttackRange
				and other.MovingUntil < soonest
			then
				coming, soonest = other, other.MovingUntil
			end
		end
		if coming then
			unit.Target = coming
			return "wait", soonest + config.SettleTime
		end
		-- O inimigo mais perto que tem vaga livre colada nele
		local enemies = {}
		for _, other in state.units do
			if other.Side ~= unit.Side and other.Alive then
				table.insert(enemies, other)
			end
		end
		table.sort(enemies, function(a, b)
			local distanceA, distanceB = flatDistance(unit.Pos3, a.Pos3), flatDistance(unit.Pos3, b.Pos3)
			if math.abs(distanceA - distanceB) > 0.01 then
				return distanceA < distanceB
			end
			return a.Key < b.Key
		end)
		for _, enemy in enemies do
			local best, bestDistance = nil, math.huge
			for index, point in Layout.Points do
				local owner = holder[index]
				if
					(owner == nil or not owner.Alive)
					and index ~= unit.Point
					and flatDistance(point, enemy.Pos3) <= config.AttackRange
				then
					local distance = flatDistance(unit.Pos3, point)
					if distance < bestDistance then
						best, bestDistance = index, distance
					end
				end
			end
			if best then
				unit.Target = enemy
				return "move", best
			end
		end
		return "wait", now + config.RetryTime
	end

	-- Hora de decidir (o alvo caiu): bate em quem está colado, espera ou anda
	local function think(unit: any)
		unit.ThinkAt = nil
		-- Andando: decide quando chegar (no turno); atordoado: não anda, decide no turno
		if not settled(unit) or unit.Stun > 0 then
			return
		end
		local kind, value = decide(unit)
		if kind == "move" then
			moveTo(unit, value :: number)
		elseif kind == "wait" then
			unit.ThinkAt = math.max(value :: number, clock + 0.05)
		end
	end

	-- Hora do turno: sem ninguém colado, anda (o turno fica para quando chegar); senão o turno do motor da Torre
	local function turn(unit: any)
		if not settled(unit) then
			unit.Next = unit.MovingUntil + config.SettleTime
			return
		end
		if unit.Stun == 0 and not state.targetOf(unit) then
			local kind, value = decide(unit)
			if kind == "move" then
				moveTo(unit, value :: number)
				return
			elseif kind == "wait" then
				unit.Next = math.max(unit.Next, value :: number)
				return
			end
		end
		core.takeTurn(state, unit)
		if unit.Alive then
			unit.Next = math.max(unit.Next, clock + cursor + config.RecoverTime / turnRate)
		end
	end

	---------------------------------------------------------------- a luta

	-- Começo (escudos, arrancada, Gravidade) e todos andam até o lugar do par, já com o alvo marcado
	core.startBattle(state)
	for _, unit in state.units do
		local side, slot = Layout.opponent(unit.Side, unit.Slot)
		unit.Target = byKey[side .. slot]
		moveTo(unit, Layout.fightPoint(unit.Side, unit.Slot))
		if not unit.Target then
			unit.ThinkAt = unit.MovingUntil + config.SettleTime
		end
	end

	local reason = "KO"
	local steps = 0
	local overtimeShown = 0
	while aliveSides() > 1 do
		steps += 1
		if steps > MAX_STEPS then
			reason = "TimeLimit"
			break
		end
		local chosen, thinking, time = nil, false, math.huge
		for _, unit in state.units do
			if unit.Alive then
				if unit.Next < time then
					chosen, thinking, time = unit, false, unit.Next
				end
				if unit.ThinkAt and unit.ThinkAt < time then
					chosen, thinking, time = unit, true, unit.ThinkAt
				end
			end
		end
		if not chosen then
			break
		end
		if time > config.MaxSeconds then
			reason = "TimeLimit"
			break
		end
		-- Degraus da morte súbita que chegaram antes desta ação: aviso na tela na hora certa
		while overtimeShown < overtimeLevel(time) do
			overtimeShown += 1
			local at = overtime.Start + (overtimeShown - 1) * overtime.Every
			core.emit(state, {
				T = "Overtime",
				Level = overtimeShown,
				Pct = overtimeShown * overtime.Bonus,
				At = round2(at),
			})
		end
		clock, cursor, strikes, comboBase, turnRate = math.max(clock, time), 0, 0, 0, 1
		if thinking then
			think(chosen)
		else
			turn(chosen)
		end
	end

	-- Colocação: quem está de pé primeiro (pela fração de Vida), depois quem caiu por último
	local placement = table.clone(order)
	table.sort(placement, function(a, b)
		local fallenA, fallenB = eliminatedAt[a], eliminatedAt[b]
		if (fallenA == nil) ~= (fallenB == nil) then
			return fallenA == nil
		end
		if fallenA == nil then
			local shareA, shareB = hpShare(a), hpShare(b)
			if math.abs(shareA - shareB) > 1e-9 then
				return shareA > shareB
			end
			return a < b
		end
		if math.abs(fallenA - (fallenB :: number)) > 1e-6 then
			return fallenA > (fallenB :: number)
		end
		return a < b
	end)
	local winner = placement[1]
	core.emit(state, { T = "End", Winner = winner, Reason = reason })

	local finalHp, eliminated = {}, {}
	for _, unit in state.units do
		finalHp[unit.Key] = if unit.Alive then unit.Hp else 0
	end
	for side, at in eliminatedAt do
		eliminated[side] = round2(at)
	end
	return {
		Version = SCRIPT_VERSION,
		Seed = seed,
		Mode = "ArenaBattle",
		Units = info,
		Events = state.events,
		Result = {
			Winner = winner,
			Reason = reason,
			Placement = placement,
			Eliminated = eliminated,
			FinalHp = finalHp,
			WorldTime = round2(lastAt),
			-- segundos de tela: o tempo do mundo + as paradas do Za Warudo + a folga do fim
			Duration = round2(lastAt + totalStop + config.EndTail),
		},
	}
end

return ArenaEngine
]=]
SOURCES["src/server/Combat/BattleEngine.luau"] = [=[
--[[
	BattleEngine — o motor da luta por turnos (Torre, duelos e Arena usam o mesmo).

		BattleEngine.run(sideA, sideB, options) → Script (o "roteiro")

	Calcula a luta INTEIRA de uma vez, com um gerador sorteado pela semente (Random.new(seed): a mesma
	semente repete a mesma luta), e devolve o roteiro: a lista de tudo que aconteceu, já com os números.
	O cliente só anima (Client/Controllers/BattleController). Regras em docs/design-etapas-6-8.md, parte 3:

	  Linha do tempo: cada brainrot tem um relógio Next; age quem tiver o menor; depois do turno,
	  Next += ActionTime / Velocidade atual. Alvo: sempre o primeiro vivo da fila inimiga.
	  Turno: queimadura → regeneração → fúria → (atordoado? perde a ação) → extra "antes" (bomba) →
	  ataque principal (padrão de ataques) → extra "depois" → enfraquecimentos descontam → próximo Next.
	  Golpe: esquiva → variação → crítico → multiplicadores → redução → arredonda → escudo → Vida →
	  roubo de vida → espinhos → efeitos de acerto (atordoar, queimar, enfraquecer) → quem chegou a 0.

	sideA = quem desafia (o jogador na Torre), sideB = quem defende. Cada lado: 1 a 3 UnitSpec, na ordem
	da fila (1 = frente). A passiva vem de SpeciesConfig.get(spec.Passive).Passive.Effects.

	Ganchos do estado (08/11/2026, evento Arena de 4 times: Server/Combat/ArenaEngine): sem eles vale a luta de 2
	lados de sempre. targetOf(unit) = quem ele golpeia agora (padrão: o primeiro vivo da fila inimiga); areaOf(unit) =
	quem o golpe em área pega (padrão: o lado inimigo inteiro); startFoes(unit) = quem o enfraquecimento do início
	pega; onDeath(unit) = alguém caiu; stamp(event) = carimba a hora do evento (false = não guarda). O motor da Arena
	usa as mesmas regras de golpe por BattleEngine.Core.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local ArtifactConfig = require(Shared.Config.ArtifactConfig)
local CombatConfig = require(Shared.Config.CombatConfig)
local SpeciesConfig = require(Shared.Config.SpeciesConfig)
local PassivePower = require(Shared.Brainrot.PassivePower)

export type UnitSpec = {
	Species: string,
	Passive: string, -- espécie de onde vem a passiva
	Level: number,
	Stars: number,
	Mutation: string?, -- mutação (Config/MutationConfig), só para o modelo da tela (19/11/2026)
	Stats: { Hp: number, Atk: number, Spd: number },
	SpdTalent: number, -- desempate na linha do tempo
	BossName: string?,
	Scale: number?,
	Size: number?, -- % de tamanho (SizeConfig), só para o balão de stats da tela
	MaxHpHitShare: number?, -- eficácia da Jakalopita (MaxHpHit) contra este (chefão do rodízio: ArtifactConfig.MaxHpHitBossShare)
	SuperBoss: boolean?, -- Super chefe (o chefão do rodízio da Torre): DodgeRiposte faz só SuperBossShare do dano nele
	StartHp: number?, -- começa com esta Vida (subida da Torre: a Vida não volta entre os andares)
	ExtraEffects: { SpeciesConfig.Effect }?, -- efeitos a mais, além da passiva (árvore de skills do dono)
	ArtifactEffects: { SpeciesConfig.Effect }?, -- efeitos do artefato equipado (ArtifactConfig)
	Artifacts: { string }?, -- ids dos artefatos, só para o balão de stats da tela (16/11/2026)
}

-- Aura na hora (15/11/2026, pedido do usuário; Torre e Chefão): OnKill(chave de quem caiu do lado B) devolve a Aura
-- que ele deu (número em cima dele) e quem do lado A subiu de nível, com os stats novos. O motor aplica na hora: a Vida
-- máxima cresce e a Vida atual sobe o mesmo tanto; Ataque e Velocidade trocam. Eventos "KillAura" e "LevelUp"
export type KillGain = { Level: number, Stats: { Hp: number, Atk: number, Spd: number }? }
export type KillResult = { Aura: number, Gains: { [string]: KillGain } }

export type Options = {
	Mode: string, -- "Tower" | "Duel" | "Arena"
	Seed: number?,
	Floor: number?,
	OnKill: ((key: string) -> KillResult?)?,
}

export type Script = {
	Version: number,
	Seed: number,
	Mode: string,
	Floor: number?,
	Units: { [string]: any },
	Events: { { [string]: any } },
	Result: {
		Winner: string,
		Reason: string,
		Turns: number,
		HpA: number,
		HpB: number,
		Duration: number,
		FinalHp: { [string]: number }, -- Vida de cada um no fim (0 = caiu)
	},
}

type Effect = SpeciesConfig.Effect

type Debuff = { Stat: string, Percent: number, Turns: number }

type Unit = {
	Key: string,
	LastAt: number, -- hora do último turno dele (o próximo é recalculado a partir daqui se a Velocidade mudar)
	Side: string,
	Pos: number,
	MaxHp: number,
	Hp: number,
	Atk: number,
	Spd: number,
	SpdTalent: number,
	Shield: number,
	Alive: boolean,
	Next: number,
	PassiveId: string,
	PassiveName: string,
	Effects: { [string]: { Effect } }, -- por tipo
	Stun: number,
	Vulnerable: number, -- dano extra recebido enquanto atordoado
	StunImmune: boolean,
	Burn: { Percent: number, Turns: number }?,
	Debuffs: { [string]: Debuff },
	Fury: number,
	Guard: number, -- redução de dano que sobe por turno (AttackStacking GuardPerTurn; 15/11/2026)
	InitiativeTurns: number,
	InitiativeBonus: number,
	Attacks: number,
	PendingBonus: number,
	Revives: number,
	ActionTime: number, -- intervalo entre turnos = isto / Velocidade (a Arena troca por segundos)
	IntervalOf: ((speed: number) -> number)?, -- Arena: intervalo em s pela Velocidade atual (no lugar do ActionTime)
	[string]: any, -- campos do motor da Arena (posição, alvo...)
}

type State = {
	rng: Random,
	units: { Unit },
	sides: { [string]: { Unit } },
	events: { { [string]: any } },
	turns: number,
	tieSide: string?,
	emptiedFirst: string?, -- lado que ficou sem ninguém primeiro (DeathBlast)
	-- Ganchos da Arena (ver o cabeçalho); nil = luta de 2 lados
	targetOf: ((Unit) -> Unit?)?,
	areaOf: ((Unit) -> { Unit })?,
	startFoes: ((Unit) -> { Unit })?,
	onDeath: ((Unit) -> ())?,
	stamp: (({ [string]: any }) -> boolean?)?,
	-- Arena (13/11/2026, pedido do usuário): "1 turno" vira turnSeconds segundos do mundo; now() = a hora do mundo
	turnSeconds: number?,
	now: (() -> number)?,
	damageBonus: (() -> number)?, -- Arena: multiplicador do dano de todos (morte súbita)
	[string]: any,
}

local SCRIPT_VERSION = 2
local NO_EFFECTS: { Effect } = {}
local STATUS_OF_STAT = { Atk = "AtkDown", Spd = "SpdDown" }

local BattleEngine = {}

local function round(value: number): number
	return math.floor(value + 0.5)
end

local function roundTo(value: number, decimals: number): number
	local factor = 10 ^ decimals
	return math.floor(value * factor + 0.5) / factor
end

local function emit(state: State, event: { [string]: any })
	if state.stamp and state.stamp(event) == false then
		return
	end
	table.insert(state.events, event)
end

local function roll(state: State, chance: number?): boolean
	local value = chance or 0
	if value >= 1 then
		return true
	elseif value <= 0 then
		return false
	end
	return state.rng:NextNumber() < value
end

local function effects(unit: Unit, kind: string): { Effect }
	return unit.Effects[kind] or NO_EFFECTS
end

-- Penetração (Chamas de Goes, efeito Pierce; 15/11/2026): soma do campo `field` ("ShieldPierce" ou "ReductionPierce")
-- de quem bate, até 100%
local function pierceOf(unit: Unit, field: string): number
	local total = 0
	for _, effect in effects(unit, "Pierce") do
		total += (effect :: any)[field] or 0
	end
	return math.min(1, total)
end

local function other(side: string): string
	return if side == "A" then "B" else "A"
end

local function front(state: State, side: string): Unit?
	for _, unit in state.sides[side] do
		if unit.Alive then
			return unit
		end
	end
	return nil
end

-- Quem ele golpeia agora: na luta de 2 lados, o primeiro vivo da fila inimiga; na Arena, o gancho decide
local function targetOf(state: State, unit: Unit): Unit?
	-- Alvo agarrado pela mordida do Glorbo (Grab): os inimigos dele batem nele enquanto estiver de pé
	local grabbed = state.grabbed :: Unit?
	if grabbed and grabbed.Alive and grabbed.Hp > 0 and grabbed.Side ~= unit.Side then
		return grabbed
	end
	if state.targetOf then
		return state.targetOf(unit)
	end
	return front(state, other(unit.Side))
end

-- Quem um golpe em área pega: o lado inimigo inteiro, ou (Arena) os inimigos perto dele
local function areaOf(state: State, unit: Unit): { Unit }
	if state.areaOf then
		return state.areaOf(unit)
	end
	return state.sides[other(unit.Side)]
end

-- Produto dos enfraquecimentos de um stat, nunca abaixo de MinStatFactor.
-- Lentidão (17/11/2026, pedido do usuário): fontes diferentes não somam, vale só a MAIS FORTE; as outras continuam
-- guardadas contando o tempo delas e voltam a valer quando a mais forte acaba
local function debuffFactor(unit: Unit, stat: string): number
	local factor, strongest = 1, 0
	for _, debuff in unit.Debuffs do
		if debuff.Stat == stat then
			if stat == "Spd" then
				strongest = math.max(strongest, debuff.Percent)
			else
				factor *= 1 - debuff.Percent
			end
		end
	end
	return math.max(CombatConfig.MinStatFactor, factor * (1 - strongest))
end

local function attackOf(unit: Unit): number
	return unit.Atk * (1 + unit.Fury) * debuffFactor(unit, "Atk")
end

local function speedOf(unit: Unit): number
	local bonus = if unit.InitiativeTurns > 0 then unit.InitiativeBonus else 0
	return math.max(0.01, unit.Spd * debuffFactor(unit, "Spd") * (1 + bonus))
end

-- Tempo entre dois turnos pela Velocidade atual (com lentidão e bônus). A Arena troca a conta por IntervalOf.
local function intervalOf(unit: Unit): number
	if unit.IntervalOf then
		return unit.IntervalOf(speedOf(unit))
	end
	return unit.ActionTime / speedOf(unit)
end

-- Dano direto (queimadura, espinhos, golpe). Escudo (07/11/2026, pedido do usuário): com qualquer escudo, o golpe
-- inteiro bate só no escudo (tira até o escudo todo e o que sobra se perde); a Vida só cai no golpe seguinte.
-- Retorna quanto do golpe o escudo segurou.
-- pierce = penetração de escudo de quem bateu (Chamas de Goes, 15/11/2026): do que passa do escudo, esta fração chega
-- na Vida (1001 de dano em 1 de escudo com 50% = 500 na Vida)
local function hurt(unit: Unit, amount: number, pierce: number?): number
	if unit.Shield > 0 then
		-- Penetração de escudo (Chamas de Goes, 16/11/2026, pedido do usuário): esta fração do golpe vai direto na Vida e
		-- o resto bate no escudo (40% = 40% na Vida, 60% no escudo; o que passar do escudo se perde, como sempre)
		local through = if (pierce or 0) > 0 then round(amount * math.min(1, pierce :: number)) else 0
		unit.Shield = math.max(0, unit.Shield - (amount - through))
		if through > 0 then
			unit.Hp = math.max(0, unit.Hp - through)
		end
		return amount - through
	end
	unit.Hp = math.max(0, unit.Hp - amount)
	return 0
end

-- name = de onde vem a cura quando não é a passiva (artefato): a tela mostra na hora da pancada
-- steal = cura do roubo de vida (Lifesteal no evento: a tela mostra junto com o golpe)
-- silent = cura de efeito Silent (artefato, árvore): sem nome de habilidade na tela (16/11/2026: a Lâmina de Dante
-- mostrava o texto da habilidade do brainrot em todo golpe)
local function heal(
	state: State,
	unit: Unit,
	amount: number,
	source: Unit?,
	name: string?,
	steal: boolean?,
	silent: boolean?
)
	local healed = math.min(amount, unit.MaxHp - unit.Hp)
	if healed > 0 and unit.Alive and unit.Hp > 0 then
		unit.Hp += healed
		emit(state, {
			T = "Heal",
			U = unit.Key,
			Amount = healed,
			Hp = unit.Hp,
			Passive = if silent then nil else name or (if source then source.PassiveName else unit.PassiveName),
			Source = if source then source.Key else nil,
			Artifact = if name then true else nil,
			Lifesteal = if steal then true else nil,
		})
	end
end

-- Maçã (artefato): conta os golpes que acertaram, dados ou levados; a cada Every, cura Percent da Vida máxima.
-- Com Dealt (Trulimero, 14/11/2026): só os golpes que ELE deu contam. dealt = este golpe foi dele
local function countHit(state: State, unit: Unit, dealt: boolean)
	local list = effects(unit, "HealEveryHits")
	if #list == 0 then
		return
	end
	local holder = unit :: any
	holder.HitCount = (holder.HitCount or 0) + 1
	if dealt then
		holder.DealtCount = (holder.DealtCount or 0) + 1
	end
	for _, effect in list do
		local every = effect.Every or 0
		local count = if (effect :: any).Dealt then (if dealt then holder.DealtCount else 0) else holder.HitCount
		if every > 0 and count > 0 and count % every == 0 then
			heal(state, unit, round((effect.Percent or 0) * unit.MaxHp), nil, (effect :: any).Name)
		end
	end
end

-- Arena: durações em segundos (state.turnSeconds). Nil = luta por turnos (as durações contam os turnos de quem sofre)
local function timed(state: State): number?
	return state.turnSeconds
end

local function worldNow(state: State): number
	return if state.now then state.now() else 0
end

-- Levou dano (golpe, espinhos, explosão de escudo, queimadura) e continua de pé (13/11/2026, pedido do usuário):
--   HurtCharge (Pirueta da Ballerina): o próximo ataque dela dá Multiplier o dano
--   LowHpRush (Sem Sinal do Pot Hotspot): a Vida caiu abaixo de uma das marcas (Thresholds; mais marcas com as
--   estrelas) → o próximo turno é dele (na Arena: ataca na hora, o tempo do ataque recomeça do zero). Cada marca vale
--   uma vez na luta; um golpe que passa de duas dá um turno só.
local function onHurt(state: State, unit: Unit)
	if not unit.Alive or unit.Hp <= 0 then
		return
	end
	local holder = unit :: any
	for _, effect in effects(unit, "HurtCharge") do
		local multiplier = effect.Multiplier or 1
		if multiplier > (holder.Charged or 1) then
			holder.Charged = multiplier
			emit(state, { T = "Charge", U = unit.Key, Mult = multiplier, Passive = unit.PassiveName })
		end
	end
	for _, effect in effects(unit, "LowHpRush") do
		holder.RushCrossed = holder.RushCrossed or {}
		if PassivePower.crossThresholds(effect, holder.RushCrossed, unit.Hp / unit.MaxHp) then
			holder.Rush = true
			local now = if timed(state) then worldNow(state) else (state.clock or unit.Next)
			unit.Next = math.min(unit.Next, now)
			emit(state, { T = "Rush", U = unit.Key, Passive = unit.PassiveName })
		end
	end
end

-- Quem chegou a 0 de Vida: volta (Sete Vidas) ou cai
local function checkDown(state: State, unit: Unit, killer: Unit?)
	if not unit.Alive or unit.Hp > 0 then
		return
	end
	local revive = effects(unit, "Revive")[1]
	if revive and unit.Revives < (revive.Uses or 1) then
		unit.Revives += 1
		unit.Hp = math.max(1, round((revive.Percent or 0) * unit.MaxHp))
		unit.Burn = nil
		unit.Stun = 0
		table.clear(unit.Debuffs)
		unit.Vulnerable = 0
		unit.Fury += revive.Fury or 0
		emit(state, { T = "Revive", U = unit.Key, Hp = unit.Hp, Passive = unit.PassiveName })
		return
	end
	unit.Alive = false
	-- Explosão ao morrer (DeathBlast, Bombombini Gusini; 15/11/2026, pedido do usuário): quem o derrubou leva
	-- Multiplier × o Ataque dele, direto (sem esquiva). Sai no MESMO instante da queda (o evento vem antes do "Death",
	-- a tela mostra os dois juntos), mas conta DEPOIS: se o time dele acabou aqui, ele já perdeu (emptiedFirst), mesmo
	-- que a explosão derrube o último do outro time
	local blasts = if killer and killer.Alive and killer.Hp > 0 then effects(unit, "DeathBlast") else {}
	local blasted = false
	for _, effect in blasts do
		if killer and killer.Alive and killer.Hp > 0 then
			local blast = math.max(1, round((effect.Multiplier or 1) * attackOf(unit)))
			hurt(killer, blast)
			emit(state, {
				T = "DeathBlast",
				U = unit.Key,
				Target = killer.Key,
				Dmg = blast,
				Hp = killer.Hp,
				Shield = killer.Shield,
				Passive = unit.PassiveName,
			})
			blasted = true
		end
	end
	emit(state, { T = "Death", U = unit.Key })
	if blasted and not state.emptiedFirst then
		local standing = false
		for _, mate in state.sides[unit.Side] do
			standing = standing or mate.Alive
		end
		if not standing then
			state.emptiedFirst = unit.Side
		end
	end
	if state.onDeath then
		state.onDeath(unit)
	end
	if blasted and killer then
		checkDown(state, killer)
	end
end

-- Lista das lentidões de um brainrot para a tela (17/11/2026, pedido do usuário): um ícone por fonte, só a mais forte
-- vale (Active). Evento "Slows" { U, List = { { Pct, Turns, Until, Active } } }, mandado sempre que a lista muda
local function emitSlows(state: State, unit: Unit)
	local list, strongest = {}, nil
	for key, debuff in unit.Debuffs do
		if debuff.Stat == "Spd" then
			local entry = { Key = key, Pct = debuff.Percent, Turns = debuff.Turns, Until = (debuff :: any).Until }
			table.insert(list, entry)
			if not strongest or entry.Pct > strongest.Pct then
				strongest = entry
			end
		end
	end
	table.sort(list, function(a, b)
		if a.Pct ~= b.Pct then
			return a.Pct > b.Pct
		end
		return a.Key < b.Key
	end)
	for _, entry in list do
		entry.Active = entry == strongest or nil
		entry.Key = nil
	end
	emit(state, { T = "Slows", U = unit.Key, List = list })
end

local function hasDebuff(unit: Unit, stat: string): boolean
	for _, debuff in unit.Debuffs do
		if debuff.Stat == stat then
			return true
		end
	end
	return false
end

-- Enfraquecimento: o mesmo, vindo da mesma passiva, não acumula (só renova). Retorna se mudou algo.
-- Nada dura para sempre (12/11/2026): Turns ausente ou 0 vira CombatConfig.MinDebuffTurns
local function debuffTurns(effect: any): number
	return math.max(CombatConfig.MinDebuffTurns, math.floor(tonumber(effect.Turns) or 0))
end

local function applyDebuff(state: State, source: Unit, target: Unit, effect: Effect): boolean
	local stat = effect.Stat or "Atk"
	local key = `{source.PassiveId}:{stat}`
	local turns = debuffTurns(effect)
	local seconds = timed(state)
	-- Arena: dura turnos × turnSeconds a partir de agora (Until); na luta por turnos, Turns conta os turnos dele
	local untilAt = if seconds then worldNow(state) + turns * seconds else nil
	local existing = target.Debuffs[key]
	if existing then
		if untilAt then
			if (existing.Until or 0) >= untilAt then
				return false
			end
			existing.Until = untilAt
			if stat == "Spd" then
				emitSlows(state, target)
			end
			return true
		end
		if existing.Turns >= turns then
			return false
		end
		existing.Turns = turns
		if stat == "Spd" then
			emitSlows(state, target)
		end
		return true
	end
	target.Debuffs[key] = { Stat = stat, Percent = effect.Percent or 0, Turns = turns, Until = untilAt } :: any
	if stat == "Spd" then
		emitSlows(state, target)
	end
	-- Velocidade mudou: o próximo turno dele é recalculado inteiro com a velocidade nova, a partir do último
	-- (06/11/2026, pedido do usuário: quem ia jogar logo depois pode passar para trás de outro)
	if stat == "Spd" then
		target.Next = math.max(target.Next, target.LastAt + intervalOf(target))
	end
	return true
end

local function tryStun(
	state: State,
	source: Unit,
	target: Unit,
	turns: number,
	passiveName: string,
	vulnerable: number?,
	trap: boolean?
)
	local seconds = timed(state)
	if seconds then
		-- Arena: atordoado até StunUntil (turnos × turnSeconds); Stun > 0 só marca que está atordoado
		local untilAt = worldNow(state) + turns * seconds
		if target.StunImmune or (target.Stun > 0 and untilAt <= (target.StunUntil or 0)) then
			return
		end
		target.StunUntil = untilAt
		target.Stun = math.max(target.Stun, turns)
	else
		if target.StunImmune or turns <= target.Stun then
			return
		end
		target.Stun = turns
	end
	if vulnerable and vulnerable > target.Vulnerable then
		target.Vulnerable = vulnerable
	end
	emit(state, {
		T = "Status",
		U = source.Key,
		Target = target.Key,
		Status = "Stun",
		Turns = turns,
		Trap = trap,
		Passive = passiveName,
	})
end

-- Efeitos de acerto do atacante (o alvo levou dano e continua de pé)
local function applyOnHit(state: State, attacker: Unit, target: Unit, patternStun: number?)
	if patternStun and patternStun > 0 then
		tryStun(state, attacker, target, patternStun, attacker.PassiveName)
	end
	for _, effect in effects(attacker, "Stun") do
		if roll(state, effect.Chance) then
			tryStun(state, attacker, target, effect.Turns or 1, attacker.PassiveName, effect.Vulnerable)
		end
	end
	for _, effect in effects(attacker, "Burn") do
		if roll(state, effect.Chance) then
			local turns = effect.Turns or 1
			local current = target.Burn
			local seconds = timed(state)
			-- Arena: queima a cada turnSeconds (NextTick), Turns vezes
			local renew = if seconds
				then not current or (current :: any).Until < worldNow(state) + turns * seconds
				else not current or current.Turns < turns
			if renew then
				-- By = quem queimou (o dano da queimadura conta para ele na tabela de dano; Shared/Brainrot/BattleDamage)
				local burn: any = { Percent = effect.Percent or 0, Turns = turns, By = attacker.Key }
				if seconds then
					local at = worldNow(state)
					burn.Until = at + turns * seconds
					burn.NextTick = at + seconds
				end
				target.Burn = burn
				emit(state, {
					T = "Status",
					U = attacker.Key,
					Target = target.Key,
					Status = "Burn",
					Turns = turns,
					Pct = effect.Percent,
					Passive = attacker.PassiveName,
				})
			end
		end
	end
	for _, effect in effects(attacker, "Debuff") do
		if not effect.AtStart and roll(state, effect.Chance or 1) and applyDebuff(state, attacker, target, effect) then
			emit(state, {
				T = "Status",
				U = attacker.Key,
				Target = target.Key,
				Status = STATUS_OF_STAT[effect.Stat or "Atk"],
				Turns = debuffTurns(effect),
				Pct = effect.Percent,
				Passive = attacker.PassiveName,
			})
		end
	end
end

type StrikeOptions = {
	Multiplier: number?,
	ForcedCrit: number?, -- crítico garantido com esse multiplicador (padrão de ataques)
	StunTurns: number?,
	Passive: string?, -- passiva que aparece no golpe
	Fx: string?, -- animação especial na tela da luta
	FxFirst: boolean?, -- primeiro golpe da animação (golpe em área: um evento por alvo)
	Chain: number?, -- 2º, 3º extra seguido
	All: boolean?, -- golpe em área
	Wave: {}?, -- o mesmo golpe em área (todos os alvos dele): o Julgamento de Eyros sai em todos, com 33%
	Assist: boolean?, -- golpe no alvo agarrado (Grab do Glorbo; o strike também marca sozinho pelo state.grabbed)
	Basic: boolean?, -- ataque básico (não é passo de habilidade): o que o RetaliateDebuff do alvo responde
	-- Dano verdadeiro (revide do Cappuccino, 17/11/2026): atravessa 100% da redução de dano e do escudo
	True: boolean?,
}

local riposte: (State, Unit, Unit, StrikeOptions) -> ()

-- Roubo de vida (14/11/2026, pedido do usuário: vale para TODO dano que o brainrot causa): golpe, Jakalopita, Julgamento,
-- espinhos, escudo que explode e queimadura
local function stealLife(state: State, unit: Unit, amount: number)
	if amount <= 0 then
		return
	end
	for _, effect in effects(unit, "Lifesteal") do
		heal(state, unit, round((effect.Percent or 0) * amount), nil, nil, true, (effect :: any).Silent)
	end
end

-- Crítico de um golpe: base (CombatConfig) + Crit das passivas/árvore + ForcedCrit. Crítico recarrega a esquiva
-- garantida (FirstDodge do Cappuccino), até Recharges vezes na luta; simulate = só a conta, sem recarregar
local function rollCrit(state: State, attacker: Unit, options: StrikeOptions, simulate: boolean?): (number, boolean)
	-- Um sorteio só (20/11/2026, pedido do usuário): as chances SOMAM (base + passivas + árvore + artefatos), igual à
	-- tela; 100%+ nunca falha. Multiplicador = o maior das fontes; nome da passiva se alguma não-Silent tiver chance
	local chance, multiplier, named = CombatConfig.BaseCritChance, CombatConfig.BaseCritMultiplier, false
	for _, effect in effects(attacker, "Crit") do
		chance += effect.Chance or 0
		multiplier = math.max(multiplier, effect.Multiplier or CombatConfig.BaseCritMultiplier)
		if (effect.Chance or 0) > 0 and not (effect :: any).Silent then
			named = true
		end
	end
	local crit, critByPassive = 1, false
	if chance >= 1 or roll(state, chance) then
		crit, critByPassive = multiplier, named
	end
	if options.ForcedCrit and options.ForcedCrit > crit then
		crit, critByPassive = options.ForcedCrit, true
	end
	-- Crítico recarrega a esquiva garantida (FirstDodge), até Recharges vezes na luta
	if crit > 1 and not simulate then
		for _, effect in effects(attacker, "FirstDodge") do
			local holder = attacker :: any
			-- Sem Recharges = sem limite (Cappuccino desde 16/11/2026)
			if
				holder.FirstDodgeSpent
				and (effect.Recharges == nil or (holder.FirstDodgeRecharges or 0) < effect.Recharges)
			then
				holder.FirstDodgeSpent = false
				holder.FirstDodgeRecharges = (holder.FirstDodgeRecharges or 0) + 1
			end
		end
	end
	return crit, critByPassive
end

-- Dano de um golpe que acertou: Ataque efetivo × variação × crítico × multiplicadores × redução. simulate = só a conta
-- (revide do Cappuccino: o dano que ele tomaria do golpe que esquivou), sem recarregar esquiva de ninguém
local function rollDamage(
	state: State,
	attacker: Unit,
	target: Unit,
	options: StrikeOptions,
	simulate: boolean?
): (number, number, boolean, boolean, boolean, string?, boolean, number, number)
	local variation = state.rng:NextNumber(CombatConfig.DamageMin, CombatConfig.DamageMax)
	local crit, critByPassive = rollCrit(state, attacker, options, simulate)
	local executed = false
	for _, effect in effects(attacker, "Execute") do
		local multiplier = effect.Multiplier or 1
		if target.Hp <= (effect.Threshold or 0) * target.MaxHp and multiplier > crit then
			crit, critByPassive, executed = multiplier, true, true
		end
	end
	local reduction, shownReduction = 1, false
	for _, effect in effects(target, "DamageReduction") do
		if roll(state, effect.Chance or 1) then
			reduction *= 1 - (effect.Percent or 0)
			shownReduction = shownReduction or not (effect :: any).Silent
		end
	end
	-- Guarda do 1º golpe (FirstHitGuard, Blueberrini; 18/11/2026): Percent de redução até levar o 1º golpe
	if not (target :: any).FirstHitTaken then
		for _, effect in effects(target, "FirstHitGuard") do
			reduction *= 1 - (effect.Percent or 0)
			shownReduction = true
		end
	end
	-- Caçador de Escudos (chefe da Torre): muito mais dano em quem está sem escudo, bem menos em quem tem
	local hunter, hunterName = 1, nil
	for _, effect in effects(attacker, "ShieldHunter") do
		if target.Shield > 0 then
			hunter *= effect.ShieldMultiplier or 1
		else
			hunter *= effect.NoShieldMultiplier or 1
			hunterName = (effect :: any).Name
		end
	end
	local shatter = target.Stun > 0 and target.Vulnerable > 0
	-- Penetração de redução de dano (Chamas de Goes, 15/11/2026): tira esta fração da redução que sobrou depois do teto
	local unpierced = math.max(1 - CombatConfig.MaxDamageReduction, reduction * (1 - (target.Guard or 0))) -- teto de 90%
	local guarded = unpierced + (1 - unpierced) * pierceOf(attacker, "ReductionPierce")
	if options.True then -- dano verdadeiro: nenhuma redução vale
		unpierced, guarded, shownReduction = 1, 1, false
	end
	local raw = attackOf(attacker)
		* hunter
		* variation
		* crit
		* (options.Multiplier or 1)
		* guarded
		* (if shatter then 1 + target.Vulnerable else 1)
		* (if state.damageBonus then state.damageBonus() else 1)
	local damage = math.max(1, round(raw))
	-- Dano a mais só pela penetração de redução (tabela de dano: pedaço "Chamas de Goes"; 15/11/2026, pedido do usuário)
	local pierced = if guarded > unpierced
		then math.max(0, damage - math.max(1, round(raw * unpierced / guarded)))
		else 0
	-- Dano sem NENHUMA redução (DamageReduction, Guarda do 1º golpe, Guard): base dos espinhos (18/11/2026, pedido do
	-- usuário: espinhos são pré-mitigação, redução de dano não diminui o que volta)
	local unreduced = if guarded > 0 then math.max(1, round(raw / guarded)) else damage
	return damage, crit, critByPassive, executed, shownReduction, hunterName, shatter, pierced, unreduced
end

-- Um golpe: "Attack" (principal), "Extra", "Blow" (golpe a mais do padrão) ou "Counter". Devolve se acertou (false =
-- o alvo esquivou)
-- Casca de Coco: conta um golpe dado ou levado (definida perto do playTurn)
local shellCount: (State, Unit) -> ()

local function strike(
	state: State,
	attacker: Unit,
	target: Unit,
	kind: string,
	hit: number,
	options: StrikeOptions
): boolean
	-- 1. Esquiva do alvo (contra-ataque não pode ser esquivado)
	-- Esquiva garantida do 1º golpe (Golpe Ninja do Cappuccino): fica pronta de novo quando ele acerta um crítico
	if kind ~= "Counter" then
		local holder = target :: any
		if effects(target, "FirstDodge")[1] then
			if not holder.FirstDodgeSpent then
				holder.FirstDodgeSpent = true
				emit(state, {
					T = kind,
					U = attacker.Key,
					Target = target.Key,
					Hit = hit,
					Dmg = 0,
					Dodged = true,
					Fx = options.Fx,
					FxFirst = options.FxFirst,
					Hp = target.Hp,
					Shield = target.Shield,
					Passive = target.PassiveName,
				})
				riposte(state, target, attacker, options)
				return false
			end
		end
	end
	if kind ~= "Counter" then
		for _, dodge in effects(target, "Dodge") do
			if roll(state, dodge.Chance) then
				emit(state, {
					T = kind,
					U = attacker.Key,
					Target = target.Key,
					Hit = hit,
					Dmg = 0,
					Dodged = true,
					Miss = dodge.Miss,
					Fx = options.Fx,
					FxFirst = options.FxFirst,
					Hp = target.Hp,
					Shield = target.Shield,
					-- Esquiva do stat (base/árvore de skills, Silent) não mostra o nome da passiva
					Passive = if (dodge :: any).Silent then nil else target.PassiveName,
				})
				if (dodge.NextAttackBonus or 0) > 0 then
					target.PendingBonus = dodge.NextAttackBonus or 0
				end
				if (dodge.CounterPercent or 0) > 0 and attacker.Alive then
					strike(state, target, attacker, "Counter", 1, {
						Multiplier = dodge.CounterPercent,
						Passive = target.PassiveName,
					})
				end
				riposte(state, target, attacker, options)
				return false
			end
		end
	end

	-- 2. Dano (rollDamage: toda habilidade passa pela conta normal, 17/11/2026). Dano verdadeiro (options.True, revide
	-- do Cappuccino): atravessa 100% da redução de dano e do escudo
	local damage, crit, critByPassive, executed, shownReduction, hunterName, shatter, pierced, unreduced =
		rollDamage(state, attacker, target, options)

	-- 3. Escudo e Vida
	local hadShield = target.Shield > 0
	local hpBefore = target.Hp -- espinhos devolvem no máximo isto (07/11/2026)
	local shieldPierce = if options.True then 1 else pierceOf(attacker, "ShieldPierce")
	-- Penetração de escudo: o que passou do escudo e foi na Vida (sem ela o escudo seguraria o golpe inteiro) também é
	-- dano a mais das Chamas de Goes (Pierced no evento, só para a tabela de dano). 16/11/2026 (pedido do usuário): conta
	-- no máximo o escudo que sobrava (e a Vida): 1 de escudo e 1000 de golpe com 40% = só 1 das Chamas
	local function pierceHurt(amount: number): number
		local shieldBefore, hpNow = target.Shield, target.Hp
		local blocked = hurt(target, amount, shieldPierce)
		if shieldBefore > 0 and not options.True then
			pierced += math.min(amount - blocked, shieldBefore, hpNow)
		end
		return blocked
	end
	local absorbed = pierceHurt(damage)
	-- Jakalopita (artefato, 13/11/2026, pedido do usuário; efeito MaxHpHit): todo golpe que acerta tira mais Percent da
	-- Vida MÁXIMA do alvo, separado (a tela mostra um número roxo à parte; MaxHpHit no evento). Não conta para roubo de
	-- vida nem espinhos
	local maxHpHit = 0
	if target.Hp > 0 then
		local share = 0
		for _, effect in effects(attacker, "MaxHpHit") do
			share += effect.Percent or 0
		end
		-- Chefão do rodízio (15/11/2026, pedido do usuário): só ArtifactConfig.MaxHpHitBossShare (40%; 60% menos desde 20/11/2026) de eficácia
		share *= (target :: any).MaxHpHitShare or 1
		if share > 0 then
			maxHpHit = math.max(1, round(share * target.MaxHp))
			pierceHurt(maxHpHit)
		end
	end
	-- Julgamento de Eyros (artefato, 14/11/2026, pedido do usuário; efeito FirstStrike): durante o PRIMEIRO TURNO do
	-- brainrot (FirstTurnActive, marcado no takeTurn), todo golpe que ele acerta tira mais Percent × o Ataque dele, à
	-- parte (número amarelo; FirstStrike no evento). Ataque básico num alvo só: o extra inteiro; golpe de habilidade (padrão,
	-- extra, NUKE, Za Warudo...) ou em área (options.Wave): ArtifactConfig.FirstStrikeAreaShare (33%) da força
	local firstStrike = 0
	if target.Hp > 0 and (attacker :: any).FirstTurnActive then
		local share = 0
		for _, effect in effects(attacker, "FirstStrike") do
			share += effect.Percent or 0
		end
		if share > 0 then
			local full = kind == "Attack" and options.Basic == true and options.Wave == nil
			local efficacy = if full then 1 else ArtifactConfig.FirstStrikeAreaShare
			firstStrike = math.max(1, round(share * efficacy * attackOf(attacker)))
			pierceHurt(firstStrike)
		end
	end
	emit(state, {
		T = kind,
		U = attacker.Key,
		Target = target.Key,
		Hit = hit,
		Dmg = damage,
		MaxHpHit = if maxHpHit > 0 then maxHpHit else nil,
		FirstStrike = if firstStrike > 0 then firstStrike else nil,
		Pierced = if pierced > 0 then pierced else nil, -- dano a mais das Chamas de Goes (já dentro de Dmg e dos extras)
		Crit = crit > 1,
		True = options.True or nil, -- dano verdadeiro: número rosa choque na tela
		-- Arena (17/11/2026, pedido do usuário): ataques por segundo agora; acima de 1 a animação do básico acelera junto
		-- (habilidades e revide também, 17/11/2026)
		Rate = if attacker.IntervalOf then 1 / intervalOf(attacker) else nil,
		Reduced = shownReduction,
		Hp = target.Hp,
		Shield = target.Shield,
		Absorbed = absorbed,
		Passive = options.Passive or hunterName or (if critByPassive then attacker.PassiveName else nil),
		Fx = options.Fx,
		FxFirst = options.FxFirst,
		Execute = executed or nil,
		Shatter = shatter or nil,
		Chain = options.Chain,
		All = options.All,
		Assist = options.Assist or (state.grabbed == target) or nil,
	})
	onHurt(state, target)

	-- 4. Roubo de vida do atacante (conta o que o escudo do alvo absorveu, e o extra da Jakalopita e do Julgamento)
	stealLife(state, attacker, damage + maxHpHit + firstStrike)

	-- 5. Espinhos do alvo: valem para TODO golpe, até contra-ataque e revide (07/11/2026, pedido do usuário). O dano
	-- devolvido é direto (hurt), não é golpe: não ativa os espinhos de quem levou, nem dá para esquivar dele.
	-- Espinhos não são chance: com qualquer % sempre devolvem, no mínimo 1 de dano.
	-- Pré-mitigação (18/11/2026, pedido do usuário): a % vale sobre o dano que o golpe daria SEM a redução de dano de
	-- quem tem os espinhos (unreduced), então ter redução e espinhos juntos não se atrapalha
	do
		for _, effect in effects(target, "Reflect") do
			local percent = effect.Percent or 0
			-- No máximo a Vida que quem tem os espinhos tinha antes do golpe (100 de Vida e 400% de espinhos levando
			-- 1000 devolve 100, não 4000; pedido do usuário, 07/11/2026)
			local back = if percent > 0 then math.max(1, math.min(round(percent * unreduced), hpBefore)) else 0
			-- Espinhos passam pela redução de dano de quem bateu (19/11/2026, pedido do usuário; teto de 90%)
			if back > 0 then
				local kept = 1
				for _, guard in effects(attacker, "DamageReduction") do
					if (guard.Chance or 1) >= 1 then
						kept *= 1 - (guard.Percent or 0)
					end
				end
				kept = math.max(1 - CombatConfig.MaxDamageReduction, kept * (1 - (attacker.Guard or 0)))
				back = math.max(1, round(back * kept))
			end
			if back > 0 and attacker.Alive and attacker.Hp > 0 then
				hurt(attacker, back)
				emit(state, {
					T = "Reflect",
					U = target.Key,
					Target = attacker.Key,
					Dmg = back,
					Hp = attacker.Hp,
					Shield = attacker.Shield,
					Passive = if (effect :: any).Silent then nil else target.PassiveName,
				})
				stealLife(state, target, back)
				onHurt(state, attacker)
			end
		end
	end
	-- Golpe em área conta uma vez só para quem bateu (o 1º alvo); quem levou conta sempre
	if options.FxFirst ~= false then
		countHit(state, attacker, true)
	end
	countHit(state, target, false)
	-- Levou um golpe: conta para a Casca de Coco (Burbaloni) e pode entrar no coco na hora
	if target.Alive and target.Hp > 0 then
		shellCount(state, target)
	end
	if kind ~= "Counter" then
		-- Escudo que estoura pode explodir em quem quebrou
		if hadShield and target.Shield <= 0 and attacker.Alive and attacker.Hp > 0 then
			for _, effect in effects(target, "Shield") do
				-- 16/11/2026 (pedido do usuário): fração da Vida MÁXIMA de quem tinha o escudo (era × Ataque)
				if (effect.BreakHpDamage or 0) > 0 then
					local blast = math.max(1, round((effect.BreakHpDamage or 0) * target.MaxHp))
					hurt(attacker, blast)
					emit(state, {
						T = "ShieldBreak",
						U = target.Key,
						Target = attacker.Key,
						Dmg = blast,
						Hp = attacker.Hp,
						Shield = attacker.Shield,
						Passive = target.PassiveName,
					})
					stealLife(state, target, blast)
					onHurt(state, attacker)
				end
			end
		end
	end

	-- 6. Efeitos de acerto (só se o alvo continua de pé; o contra-ataque não aplica)
	if kind ~= "Counter" and target.Hp > 0 then
		applyOnHit(state, attacker, target, options.StunTurns)
		if kind == "Attack" and attacker.Alive and attacker.Hp > 0 then
			for _, effect in effects(target, "Trap") do
				if roll(state, effect.Chance) then
					tryStun(state, target, attacker, effect.Turns or 1, target.PassiveName, nil, true)
				end
			end
		end
		-- Quem bate nele com ataque básico leva o enfraquecimento (RetaliateDebuff; Raízes Fundas do Patapim,
		-- 14/11/2026: 25% mais lento). Golpe de habilidade não conta
		if options.Basic and attacker.Alive and attacker.Hp > 0 then
			for _, effect in effects(target, "RetaliateDebuff") do
				if roll(state, effect.Chance or 1) and applyDebuff(state, target, attacker, effect) then
					emit(state, {
						T = "Status",
						U = target.Key,
						Target = attacker.Key,
						Status = STATUS_OF_STAT[effect.Stat or "Spd"],
						Turns = debuffTurns(effect),
						Pct = effect.Percent,
						Passive = target.PassiveName,
					})
				end
			end
		end
	end

	-- 6b. Guarda do 1º golpe (FirstHitGuard, Blueberrini; 18/11/2026, pedido do usuário): o 1º golpe que ele leva na
	-- luta acaba a redução; de pé, revida com Multiplier × o Ataque dele e atordoa quem bateu por StunTurns turnos (os
	-- turnos não crescem com estrela)
	local guardHolder = target :: any
	if not guardHolder.FirstHitTaken and effects(target, "FirstHitGuard")[1] then
		guardHolder.FirstHitTaken = true
		emit(state, { T = "Expire", U = target.Key, Status = "DamageReduction" })
		for _, effect in effects(target, "FirstHitGuard") do
			if target.Hp > 0 and attacker.Alive and attacker.Hp > 0 then
				strike(state, target, attacker, "Counter", 1, {
					Multiplier = effect.Multiplier or 1,
					Passive = target.PassiveName,
					Fx = (effect :: any).Fx,
				})
				-- Arena: congelado o tempo da animação (ArenaFreeze, como o parry do Cappuccino) e depois o atordoamento
				local freeze = (effect :: any).ArenaFreeze or 0
				if timed(state) and freeze > 0 and attacker.Alive and attacker.Hp > 0 then
					local rate = math.max(1, 1 / math.max(0.01, intervalOf(target)))
					local frozen = attacker :: any
					frozen.Frozen = (frozen.Frozen or 0) + freeze / rate
				end
				local stun = (effect :: any).StunTurns or 0
				if stun > 0 and attacker.Alive and attacker.Hp > 0 then
					tryStun(state, target, attacker, stun, target.PassiveName)
				end
			end
		end
	end

	-- 7. Quem chegou a 0
	checkDown(state, target, attacker)
	checkDown(state, attacker, target)
	return true
end

-- Revide de quem esquivou (DodgeRiposte, Cappuccino Assassino): Multiplier × o Ataque DELE, como dano pronto (Flat):
-- contra-ataque, não dá para esquivar; pode critar (e o crítico recarrega a esquiva garantida). 15/11/2026, pedido do
-- usuário: não devolve mais o dano do golpe esquivado (antes: esse dano + 1,5x o Ataque dele; 07/11/2026: 3x o Ataque
-- de quem errou)
riposte = function(state: State, dodger: Unit, attacker: Unit, _options: StrikeOptions)
	if not (dodger.Alive and dodger.Hp > 0 and attacker.Alive and attacker.Hp > 0) then
		return
	end
	for _, effect in effects(dodger, "DodgeRiposte") do
		-- Limit = revides por luta (16/11/2026); a esquiva continua depois disso
		local holder = dodger :: any
		local limit = (effect :: any).Limit
		if limit and (holder.RipostesUsed or 0) >= limit then
			continue
		end
		holder.RipostesUsed = (holder.RipostesUsed or 0) + 1
		-- Super chefe (18/11/2026, pedido do usuário): o revide faz só SuperBossShare do dano (Cappuccino: metade)
		local share = if (attacker :: any).SuperBoss then (effect :: any).SuperBossShare or 1 else 1
		strike(state, dodger, attacker, "Counter", 1, {
			Multiplier = (effect.Multiplier or 0) * share,
			True = true,
			Passive = dodger.PassiveName,
			Fx = (effect :: any).Fx,
		})
		-- 17/11/2026 (pedido do usuário): o parry paralisa quem levou o revide (StunTurns, atordoado). Arena
		-- (18/11/2026, pedido do usuário): sem atordoar; quem levou fica "congelado" o tempo do parry (ArenaFreeze s,
		-- na velocidade da animação): o relógio do próximo ataque dele para (Frozen, somado no endTurn)
		local stun = (effect :: any).StunTurns or 0
		if timed(state) then
			local freeze = (effect :: any).ArenaFreeze or 0
			if freeze > 0 and attacker.Alive and attacker.Hp > 0 then
				local rate = math.max(1, 1 / math.max(0.01, intervalOf(dodger)))
				local frozen = attacker :: any
				frozen.Frozen = (frozen.Frozen or 0) + freeze / rate
			end
		elseif stun > 0 and attacker.Alive and attacker.Hp > 0 then
			tryStun(state, dodger, attacker, stun, dodger.PassiveName)
		end
	end
end

-- Passo do padrão de ataques para o ataque principal nº count (nil = ataque normal)
local function patternStep(unit: Unit, count: number): SpeciesConfig.PatternStep?
	local effect = effects(unit, "AttackPattern")[1]
	local pattern = effect and effect.Pattern
	if not pattern or #pattern == 0 then
		return nil
	end
	if effect.Repeat then
		return pattern[((count - 1) % #pattern) + 1]
	end
	return pattern[count]
end

-- Ataque extra sai? Com Every: garantido no 1º ataque e depois a cada Every ataques (1º, 4º, 7º... com Every 3;
-- 13/11/2026, Orcalero), uma vez só; sem Every: sorteio de Chance (Chain = quantas vezes pode repetir)
-- 15/11/2026 (pedido do usuário): o de Every é a habilidade do turno, NO LUGAR do ataque (skillTurn); aqui só o de Chance
local function extraFires(state: State, _unit: Unit, effect: Effect, _before: boolean, _count: number): boolean
	if (effect :: any).Every then
		return false
	end
	return roll(state, effect.Chance)
end

local function extraAttacks(state: State, unit: Unit, before: boolean)
	for _, effect in effects(unit, "ExtraAttack") do
		local count = 0
		while
			(effect.Before == true) == before
			and count < (effect.Chain or 1)
			and extraFires(state, unit, effect, before, count)
		do
			count += 1
			local target = targetOf(state, unit)
			if not target or not unit.Alive then
				return
			end
			if effect.AllTargets then
				-- Lista feita antes: quem cai no meio do bombardeio não muda os alvos
				local targets = table.clone(areaOf(state, unit))
				local first = true
				local wave = {} -- golpe em área (Julgamento de Eyros em todos os alvos)
				for _, foe in targets do
					if foe.Alive and unit.Alive then
						strike(state, unit, foe, "Extra", 1, {
							Multiplier = effect.Multiplier or 1,
							Passive = unit.PassiveName,
							Fx = effect.Fx,
							FxFirst = first,
							Wave = wave,
						})
						first = false
					end
				end
			else
				strike(state, unit, target, "Extra", 1, {
					Multiplier = effect.Multiplier or 1,
					Passive = unit.PassiveName,
					Chain = if count > 1 then count else nil,
				})
			end
		end
	end
end

-- Za Warudo sai neste ataque? Com First (Lirilì; 13/11/2026, pedido do usuário): no 1º ataque e depois a cada Every
-- (1º, 5º, 9º... com Every 4); sem First: no Every-ésimo (4º, 8º...). Os golpes da própria habilidade não contam
local function timeStopFires(effect: any, attacks: number): boolean
	local every = effect.Every or 0
	if every <= 0 or attacks <= 0 then
		return false
	end
	return if effect.First then (attacks - 1) % every == 0 else attacks % every == 0
end

-- Za Warudo: golpes com o tempo parado (ninguém mais age; nenhum relógio muda). Retorna true se saiu
local function timeStop(state: State, unit: Unit): boolean
	local fired = false
	for _, effect in effects(unit, "TimeStop") do
		if timeStopFires(effect, unit.Attacks) and unit.Alive and targetOf(state, unit) then
			fired = true
			emit(state, { T = "TimeStop", U = unit.Key, Actions = effect.Actions or 1, Passive = unit.PassiveName })
			for _ = 1, effect.Actions or 1 do
				local target = targetOf(state, unit)
				if not target or not unit.Alive then
					break
				end
				-- AllTargets (Lirilì; 13/11/2026, pedido do usuário): cada golpe acerta TODOS os inimigos da luta (na Arena,
				-- de todos os outros times, perto ou longe), juntos
				if (effect :: any).AllTargets then
					local first = true
					local wave = {}
					for _, foe in state.units do
						if foe.Side ~= unit.Side and foe.Alive and unit.Alive then
							strike(state, unit, foe, "Extra", 1, {
								Multiplier = effect.Multiplier or 1,
								Passive = unit.PassiveName,
								FxFirst = first,
								All = true,
								Wave = wave,
							})
							first = false
						end
					end
					continue
				end
				strike(
					state,
					unit,
					target,
					"Extra",
					1,
					{ Multiplier = effect.Multiplier or 1, Passive = unit.PassiveName }
				)
			end
			emit(state, { T = "TimeResume", U = unit.Key })
		end
	end
	return fired
end

-- Onda/ataque em área de Every (Orcalero): no 1º ataque e depois a cada Every (1º, 4º, 7º... com Every 3). Retorna true
-- se saiu
local function everyExtra(state: State, unit: Unit): boolean
	local fired = false
	for _, effect in effects(unit, "ExtraAttack") do
		local every = (effect :: any).Every
		if every and (unit.Attacks - 1) % every == 0 and unit.Alive then
			local target = targetOf(state, unit)
			if not target then
				break
			end
			fired = true
			if effect.AllTargets then
				local first = true
				local wave = {}
				for _, foe in table.clone(areaOf(state, unit)) do
					if foe.Alive and unit.Alive then
						strike(state, unit, foe, "Extra", 1, {
							Multiplier = effect.Multiplier or 1,
							Passive = unit.PassiveName,
							Fx = effect.Fx,
							FxFirst = first,
							Wave = wave,
						})
						first = false
					end
				end
			else
				strike(state, unit, target, "Extra", 1, {
					Multiplier = effect.Multiplier or 1,
					Passive = unit.PassiveName,
					Fx = effect.Fx,
				})
			end
		end
	end
	return fired
end

-- Ação do turno: extra "antes" → ataque principal → extra "depois"
-- NUKE de novo a cada Every ataques (a função fica mais abaixo, em nuke)
local nukeAgain: (State, Unit, any) -> ()
local act: (State, Unit) -> ()

-- Mordida que agarra (Grab, Glorbo; 13/11/2026, pedido do usuário): o alvo que levou a mordida e ficou de pé é puxado
-- para o lugar de quem mordeu ("Grab") e cada aliado vivo faz um ATAQUE INTEIRO nele (act: conta para o padrão de
-- ataques e solta as habilidades, como o 3º golpe do Tung; state.grabbed faz o targetOf mirar nele enquanto estiver de
-- pé; 13/11/2026, pedido do usuário: antes era só uma pancada simples, sem habilidade). Depois ele é solto ("Release"). O atordoamento vem
-- do StunTurns do passo. Na Arena (tempo real) não puxa: fica só o golpe e o atordoamento. Mordida dentro de outra
-- (dois Glorbos no time) só morde e atordoa
local function grab(state: State, unit: Unit, target: Unit)
	if timed(state) or state.grabbed or not (unit.Alive and unit.Hp > 0 and target.Alive and target.Hp > 0) then
		return
	end
	emit(state, { T = "Grab", U = unit.Key, Target = target.Key, Passive = unit.PassiveName })
	state.grabbed = target
	for _, ally in table.clone(state.sides[unit.Side]) do
		if ally ~= unit and ally.Alive and ally.Hp > 0 and target.Alive and target.Hp > 0 then
			act(state, ally)
		end
	end
	state.grabbed = nil
	emit(state, { T = "Release", U = unit.Key, Target = target.Key })
end

act = function(state: State, unit: Unit)
	-- Dentro do coco (Casca de Coco) não ataca, nem pela mordida do Glorbo
	if (unit :: any).Shell then
		return
	end
	extraAttacks(state, unit, true)
	if not unit.Alive or not targetOf(state, unit) then
		return
	end

	unit.Attacks += 1
	-- A cada Every ataques, mais escudo para o time todo (soma ao que ainda tiver): Câmara Fria do Frigo Camelo
	for _, effect in effects(unit, "TeamShieldEvery") do
		if unit.Attacks % (effect.Every or 1) == 0 then
			for _, ally in state.sides[unit.Side] do
				if ally.Alive then
					local base = if effect.OwnMaxHp then ally.MaxHp else unit.MaxHp
					ally.Shield += round((effect.Percent or 0) * base)
					emit(state, { T = "Shield", U = ally.Key, Amount = ally.Shield, Passive = unit.PassiveName })
				end
			end
		end
	end
	for _, effect in effects(unit, "TeamHeal") do
		if unit.Attacks % (effect.Every or 1) == 0 then
			-- Cura quem está com a menor fração de Vida (só se alguém estiver ferido)
			local worst: Unit? = nil
			for _, ally in state.sides[unit.Side] do
				if
					ally.Alive
					and ally.Hp < ally.MaxHp
					and (not worst or ally.Hp / ally.MaxHp < worst.Hp / worst.MaxHp)
				then
					worst = ally
				end
			end
			if worst then
				heal(state, worst, round((effect.Percent or 0) * unit.MaxHp), unit)
			end
		end
	end
	-- Turno de habilidade (15/11/2026, pedido do usuário): a NUKE, o Za Warudo e a onda de Every SÃO o ataque do turno,
	-- no lugar do golpe normal (antes saíam depois dele). A carga da Pirueta e o bônus guardado ficam para o próximo golpe
	local skillUsed = false
	for _, effect in effects(unit, "OpeningStrike") do
		local every = (effect :: any).Every or 0
		local due = unit.Attacks == 1 or (every > 0 and (unit.Attacks - 1) % every == 0)
		if due and unit.Alive and targetOf(state, unit) then
			nukeAgain(state, unit, effect)
			skillUsed = true
		end
	end
	if timeStop(state, unit) then
		skillUsed = true
	end
	if everyExtra(state, unit) then
		skillUsed = true
	end
	if skillUsed then
		return
	end

	local step = patternStep(unit, unit.Attacks)
	local special = step ~= nil and next(step :: any) ~= nil
	local bonus = unit.PendingBonus
	unit.PendingBonus = 0
	-- Pirueta (HurtCharge): levou dano antes → este ataque dá Charged o dano (o crítico multiplica por cima)
	local charge = (unit :: any).Charged or 1
	(unit :: any).Charged = nil
	if charge > 1 then
		-- A tela tira o sinal da carga (a xícara cheia da Ballerina)
		emit(state, { T = "Discharge", U = unit.Key })
	end
	local hits = if step and step.Hits then step.Hits else 1
	local locked = if step and step.SameTarget then targetOf(state, unit) else nil
	-- Passo em área: um golpe em cada inimigo vivo
	if step and step.AllTargets then
		hits = 0
		local multiplier = (step.Multiplier or 1) * (1 + bonus) * charge
		local struck: { Unit } = {}
		local wave = {}
		for _, foe in table.clone(areaOf(state, unit)) do
			if foe.Alive and unit.Alive then
				strike(state, unit, foe, "Attack", 1, {
					Multiplier = multiplier,
					Passive = unit.PassiveName,
					All = true,
					Wave = wave,
					Fx = step.Fx,
					FxFirst = #struck == 0,
				})
				table.insert(struck, foe)
			end
		end
		-- Enfraquecimento do passo (pneu da Boneca: -30% de Velocidade): depois de todos os golpes, para a
		-- tela tocar o ataque em área inteiro de uma vez; só em quem continua de pé
		local debuff = step.Debuff
		if debuff then
			for _, foe in struck do
				if foe.Alive and foe.Hp > 0 and applyDebuff(state, unit, foe, debuff :: any) then
					emit(state, {
						T = "Status",
						U = unit.Key,
						Target = foe.Key,
						Status = STATUS_OF_STAT[debuff.Stat] or debuff.Stat,
						Turns = debuffTurns(debuff),
						Pct = debuff.Percent,
						Passive = unit.PassiveName,
					})
				end
			end
		end
	end
	local bitten: Unit? = nil -- Grab: quem levou a mordida (e não esquivou)
	for hit = 1, hits do
		local target = locked or targetOf(state, unit)
		if locked and not locked.Alive then
			break -- o alvo caiu: as pancadas que faltavam não vão para outro
		end
		if not target or not unit.Alive then
			return
		end
		local multiplier, forcedCrit = 1, nil
		if step then
			if step.Crit then
				forcedCrit = step.Multiplier or CombatConfig.BaseCritMultiplier
			else
				multiplier *= step.Multiplier or 1
			end
			if step.FinalMultiplier and hit == hits then
				multiplier *= step.FinalMultiplier
			end
		end
		if bonus > 0 then
			multiplier *= 1 + bonus
		end
		multiplier *= charge
		local landed = strike(state, unit, target, if hit == 1 then "Attack" else "Blow", hit, {
			Multiplier = multiplier,
			ForcedCrit = forcedCrit,
			StunTurns = if step then step.StunTurns else nil,
			Passive = if special or bonus > 0 or charge > 1 then unit.PassiveName else nil,
			Fx = if step then step.Fx else nil,
			Basic = not special,
		})
		if landed and hit == 1 then
			bitten = target
		end
	end
	if step and step.Grab and bitten then
		grab(state, unit, bitten)
	end
	if step and step.HealPercent and unit.Alive then
		heal(state, unit, round(step.HealPercent * unit.MaxHp))
	end
	if unit.Alive and targetOf(state, unit) then
		extraAttacks(state, unit, false)
	end
end

local function endTurn(state: State, unit: Unit)
	-- O próximo turno é marcado ANTES de descontar: "lento por 2 turnos" atrasa os 2 próximos turnos dele
	-- (05/11/2026; antes o último turno do enfraquecimento já saía na velocidade normal)
	-- Sem Sinal (LowHpRush) disparou durante o próprio turno (espinhos): age de novo logo em seguida
	if (unit :: any).Rush then
		unit.Next = unit.LastAt
	else
		unit.Next += intervalOf(unit)
	end
	-- Congelado pelo parry do Cappuccino na Arena (Frozen, em segundos): o próximo ataque espera esse tempo a mais
	local frozenHolder = unit :: any
	if frozenHolder.Frozen then
		unit.Next += frozenHolder.Frozen
		frozenHolder.Frozen = nil
	end
	if timed(state) then
		return -- Arena: as durações acabam pela hora (expireTimed), não pelos turnos
	end
	-- Enfraquecimentos com duração recebidos por este brainrot descontam 1 turno
	local expired = {}
	local slowed = false
	for key, debuff in unit.Debuffs do
		if debuff.Turns > 0 then
			slowed = slowed or debuff.Stat == "Spd"
			debuff.Turns -= 1
			if debuff.Turns == 0 then
				unit.Debuffs[key] = nil
				expired[debuff.Stat] = true
			end
		end
	end
	if slowed then
		emitSlows(state, unit)
	end
	for _, stat in { "Atk", "Spd" } do
		if expired[stat] and not hasDebuff(unit, stat) then
			emit(state, { T = "Expire", U = unit.Key, Status = STATUS_OF_STAT[stat] })
		end
	end
	if unit.InitiativeTurns > 0 then
		-- Cada Arrancada desconta 1 turno; as que acabam saem da soma
		local rushes = (unit :: any).Rushes or {}
		unit.InitiativeBonus, unit.InitiativeTurns = 0, 0
		for index = #rushes, 1, -1 do
			local rush = rushes[index]
			rush.Turns -= 1
			if rush.Turns <= 0 then
				table.remove(rushes, index)
			else
				unit.InitiativeBonus += rush.Bonus
				unit.InitiativeTurns = math.max(unit.InitiativeTurns, rush.Turns)
			end
		end
		if unit.InitiativeTurns == 0 then
			emit(state, { T = "Expire", U = unit.Key, Status = "SpdUp" })
		end
	end
end

-- Arena: o que já passou da hora acaba (enfraquecimentos e arrancada), antes do turno
local function expireTimed(state: State, unit: Unit, now: number)
	local expired = {}
	for key, debuff in unit.Debuffs do
		local untilAt = (debuff :: any).Until
		if untilAt and untilAt <= now then
			unit.Debuffs[key] = nil
			expired[debuff.Stat] = true
		end
	end
	if expired.Spd then
		emitSlows(state, unit)
	end
	for _, stat in { "Atk", "Spd" } do
		if expired[stat] and not hasDebuff(unit, stat) then
			emit(state, { T = "Expire", U = unit.Key, Status = STATUS_OF_STAT[stat] })
		end
	end
	if unit.InitiativeTurns > 0 then
		local rushes = (unit :: any).Rushes or {}
		unit.InitiativeBonus = 0
		for index = #rushes, 1, -1 do
			if (rushes[index].Until or 0) <= now then
				table.remove(rushes, index)
			else
				unit.InitiativeBonus += rushes[index].Bonus
			end
		end
		if #rushes == 0 then
			unit.InitiativeTurns = 0
			emit(state, { T = "Expire", U = unit.Key, Status = "SpdUp" })
		end
	end
end

-- Fúria (AttackStacking): +PerTurn de ataque por turno, até Max. Com EveryTurn (15/11/2026, Patapim do Chefão) sobe a
-- cada turno de QUALQUER um na luta (everyTurn = true), não só nos dele
local function stackFury(state: State, unit: Unit, everyTurn: boolean?)
	for _, effect in effects(unit, "AttackStacking") do
		local max = effect.Max or 0
		local same = (effect.EveryTurn == true) == (everyTurn == true)
		if same and unit.Fury < max then
			unit.Fury = math.min(max, unit.Fury + (effect.PerTurn or 0))
			emit(
				state,
				{ T = "Buff", U = unit.Key, Stat = "Atk", Pct = roundTo(unit.Fury, 2), Passive = unit.PassiveName }
			)
		end
		-- Redução de dano que sobe junto (15/11/2026, Patapim do Chefão): +GuardPerTurn por turno, até GuardMax
		local guardMax = (effect :: any).GuardMax or 0
		if same and (effect :: any).GuardPerTurn and unit.Guard < guardMax then
			unit.Guard = math.min(guardMax, unit.Guard + (effect :: any).GuardPerTurn)
			emit(
				state,
				{ T = "Buff", U = unit.Key, Stat = "Def", Pct = roundTo(unit.Guard, 2), Passive = unit.PassiveName }
			)
		end
	end
end

-- Arena: quantas vezes um efeito "por turno" bate até agora (a cada turnSeconds desde `nextAt`)
local function dueTicks(nextAt: number, now: number, seconds: number, limit: number): number
	if now < nextAt then
		return 0
	end
	return math.min(limit, math.floor((now - nextAt) / seconds) + 1)
end

-- Escudo de início (Shield) num brainrot: Percent da Vida máxima dele
local function addShield(state: State, unit: Unit, effect: any)
	unit.Shield += round((effect.Percent or 0) * unit.MaxHp)
	emit(state, {
		T = "Shield",
		U = unit.Key,
		Amount = unit.Shield,
		Passive = if effect.Silent then nil else unit.PassiveName,
	})
end

-- Arrancada (Initiative): +SpeedBonus de Velocidade por Turns turnos (Arena: Turns × turnSeconds desde agora)
-- 17/11/2026 (pedido do usuário): velocidade a mais SOMA (ao contrário da lentidão). Cada fonte fica numa lista
-- (unit.Rushes) com o próprio tempo; InitiativeBonus = soma, InitiativeTurns = o maior tempo que sobra
local function startInitiative(state: State, unit: Unit, initiative: any)
	local holder = unit :: any
	holder.Rushes = holder.Rushes or {}
	local turns = initiative.Turns or 1
	local seconds = timed(state)
	table.insert(holder.Rushes, {
		Bonus = initiative.SpeedBonus or 0,
		Turns = turns,
		Until = if seconds then worldNow(state) + turns * seconds else nil,
	})
	unit.InitiativeBonus, unit.InitiativeTurns = 0, 0
	for _, rush in holder.Rushes do
		unit.InitiativeBonus += rush.Bonus
		unit.InitiativeTurns = math.max(unit.InitiativeTurns, rush.Turns)
		if rush.Until then
			unit.InitiativeUntil = math.max(unit.InitiativeUntil or 0, rush.Until)
		end
	end
	emit(state, {
		T = "Initiative",
		U = unit.Key,
		Pct = unit.InitiativeBonus,
		Turns = unit.InitiativeTurns,
		Passive = if initiative.Silent then nil else unit.PassiveName,
	})
end

-- Habilidades "de início" dos brainrots, no 1º turno de cada um (14/11/2026, pedido do usuário; antes saíam antes de
-- todo mundo agir): Arrancada (a velocidade vale a partir do próximo turno). Escudos voltaram para o início (16/11). As da
-- árvore de skills (Silent) continuam no início da luta (startBattle)
local function firstTurnSkills(state: State, unit: Unit)
	if (unit :: any).FirstTurnDone then
		return
	end
	(unit :: any).FirstTurnDone = true
	-- Escudo e escudo do time saíram daqui (16/11/2026, pedido do usuário): antes de todos agirem (startBattle)
	-- 17/11/2026: todas somam (antes só a maior)
	for _, initiative in effects(unit, "Initiative") do
		if not (initiative :: any).Silent and not (initiative :: any).AtStart then
			startInitiative(state, unit, initiative)
		end
	end
	-- A NUKE saiu daqui (15/11/2026): agora é o 1º ataque dele (act), no lugar do golpe
end

-- Casca de Coco (CocoShell, Burbaloni; 19/11/2026, pedido do usuário): no Every-ésimo turno ele entra no coco ("Shell")
-- em vez de atacar e ganha Percent de redução de dano e Thorns de espinhos. Fica Turns turnos dentro (o de entrar conta),
-- sem atacar ("ShellHold"); no turno seguinte sai ("ShellOut") e age normal. Os efeitos entram na lista do próprio
-- brainrot (unit.Effects) e saem na volta
local function shellLeave(state: State, unit: Unit)
	local holder = unit :: any
	local shell = holder.Shell
	if not shell then
		return
	end
	holder.Shell = nil
	for kind, effect in shell.Added do
		local list = unit.Effects[kind]
		local index = list and table.find(list, effect)
		if index then
			table.remove(list, index)
		end
	end
	emit(state, { T = "ShellOut", U = unit.Key })
	emit(state, { T = "Expire", U = unit.Key, Status = "DamageReduction" })
	emit(state, { T = "Expire", U = unit.Key, Status = "Thorns" })
end

-- Entra no coco (efeitos na lista dele, eventos para a tela). Pode ser no turno dele ou no meio do turno de outro
local function shellEnter(state: State, unit: Unit, effect: any)
	local holder = unit :: any
	holder.ShellCount = 0
	local turns = math.max(1, effect.Turns or 2)
	local added = {
		DamageReduction = { Type = "DamageReduction", Percent = effect.Percent or 0, Chance = 1, Silent = true },
		Reflect = { Type = "Reflect", Percent = effect.Thorns or 0, Silent = true },
	}
	for kind, extra in added do
		unit.Effects[kind] = unit.Effects[kind] or {}
		table.insert(unit.Effects[kind], extra)
	end
	-- LastTurn = o turno de entrar não conta como ataque levado
	holder.Shell = { Hits = 0, Need = turns, LastTurn = state.turns, Added = added }
	emit(state, { T = "Shell", U = unit.Key, Passive = unit.PassiveName, Fx = effect.Fx, Turns = turns })
	emit(state, {
		T = "Status",
		U = unit.Key,
		Target = unit.Key,
		Status = "DamageReduction",
		Pct = effect.Percent or 0,
		Turns = turns,
		Quiet = true,
	})
	emit(state, {
		T = "Status",
		U = unit.Key,
		Target = unit.Key,
		Status = "Thorns",
		Pct = effect.Thorns or 0,
		Turns = turns,
		Quiet = true,
	})
end

-- 19/11/2026 (pedido do usuário): entra no coco depois de Every golpes somando os que deu e os que levou (1 ataque + 1
-- golpe levado já basta). Dentro do coco não conta; depois de sair começa do zero
shellCount = function(state: State, unit: Unit)
	local holder = unit :: any
	local effect = effects(unit, "CocoShell")[1] :: any
	local shell = holder.Shell
	if shell then
		-- Dentro do coco: cada ATAQUE levado conta uma vez (vários golpes do mesmo turno, ex.: rajada do Bobrito, = 1)
		if shell.LastTurn ~= state.turns then
			shell.LastTurn = state.turns
			shell.Hits += 1
		end
		return
	end
	if not effect then
		return
	end
	holder.ShellCount = (holder.ShellCount or 0) + 1
	if holder.ShellCount >= (effect.Every or 2) then
		shellEnter(state, unit, effect)
	end
end

-- Começo do turno dele: dentro do coco? Fica Turns turnos dele sem atacar ("ShellHold") e sai no seguinte ("ShellOut"),
-- que é um turno normal. true = este turno é só ficar no coco
local function shellTurn(state: State, unit: Unit): boolean
	local shell = (unit :: any).Shell
	if not shell then
		return false
	end
	emit(state, { T = "ShellHold", U = unit.Key, Left = math.max(0, shell.Need - shell.Hits) })
	return true
end

local function playTurn(state: State, unit: Unit)
	state.turns += 1
	unit.LastAt = unit.Next
	state.clock = unit.Next; -- hora do turno que está passando (o Sem Sinal marca o próximo para esta hora)
	(unit :: any).Rush = nil -- este turno já é o que o Sem Sinal pediu
	emit(state, { T = "Turn", U = unit.Key, N = state.turns, At = roundTo(unit.Next, 2) })
	local seconds = timed(state)
	local now = worldNow(state)
	if seconds then
		expireTimed(state, unit, now)
	end
	-- Fúria que sobe a cada turno de qualquer um (EveryTurn)
	for _, fighter in state.units do
		if fighter.Alive then
			stackFury(state, fighter, true)
		end
	end

	-- 1. Início do turno (acontece mesmo atordoado). Arena: a queimadura e os efeitos "por turno" batem a cada
	-- turnSeconds, não a cada ação
	local burn: any = unit.Burn
	local burnTicks = 1
	if burn and seconds then
		burnTicks = dueTicks(burn.NextTick, now, seconds, burn.Turns)
		burn.NextTick += burnTicks * seconds
	end
	for _ = 1, if burn then burnTicks else 0 do
		local damage = math.max(1, round(burn.Percent * unit.MaxHp))
		burn.Turns -= 1
		hurt(unit, damage)
		emit(state, {
			T = "Burn",
			U = unit.Key,
			By = burn.By,
			Dmg = damage,
			Hp = unit.Hp,
			Shield = unit.Shield,
			Left = burn.Turns,
		})
		-- Quem queimou rouba vida da queimadura também
		for _, burner in state.units do
			if burner.Key == burn.By then
				stealLife(state, burner, damage)
				break
			end
		end
		onHurt(state, unit)
		if burn.Turns <= 0 then
			unit.Burn = nil
		end
		checkDown(state, unit)
		if not unit.Alive then
			return
		end
	end
	local periodic = 1
	if seconds then
		periodic = dueTicks(unit.PeriodicAt or seconds, now, seconds, math.huge)
		unit.PeriodicAt = (unit.PeriodicAt or seconds) + periodic * seconds
	end
	for _ = 1, periodic do
		for _, effect in effects(unit, "HealPerTurn") do
			heal(state, unit, round((effect.Percent or 0) * unit.MaxHp))
		end
		-- Começo do turno: cura o aliado com a menor fração de Vida, nunca ele mesmo, em Percent da Vida máxima DELE
		-- (Giraffa Celeste, 17/11/2026, pedido do usuário)
		for _, effect in effects(unit, "TurnHealAlly") do
			local worst: Unit? = nil
			for _, ally in state.sides[unit.Side] do
				if
					ally ~= unit
					and ally.Alive
					and ally.Hp < ally.MaxHp
					and (not worst or ally.Hp / ally.MaxHp < worst.Hp / worst.MaxHp)
				then
					worst = ally
				end
			end
			if worst then
				heal(state, worst, round((effect.Percent or 0) * unit.MaxHp), unit)
			end
		end
	end
	for _ = 1, periodic do
		stackFury(state, unit)
	end
	firstTurnSkills(state, unit)
	if not unit.Alive then
		return
	end

	-- 2. Atordoado perde a ação e fica imune a novo atordoamento até agir. Arena: atordoado até StunUntil; o
	-- próximo turno fica para essa hora
	if seconds and unit.Stun > 0 then
		local untilAt = unit.StunUntil or now
		if now < untilAt then
			unit.StunImmune = true
			emit(state, { T = "Skip", U = unit.Key, Reason = "Stun", Left = math.ceil((untilAt - now) / seconds) })
			unit.Next = untilAt
			return
		end
		unit.Stun, unit.StunUntil, unit.Vulnerable = 0, nil, 0
		emit(state, { T = "Expire", U = unit.Key, Status = "Stun" })
	end
	if unit.Stun > 0 then
		unit.Stun -= 1
		unit.StunImmune = true
		if unit.Stun == 0 then
			unit.Vulnerable = 0
		end
		emit(state, { T = "Skip", U = unit.Key, Reason = "Stun", Left = unit.Stun })
		-- Atordoado dentro do coco: continua no coco (só sai por ataques levados)
	else
		unit.StunImmune = false
		if not shellTurn(state, unit) then
			act(state, unit)
			-- O ataque dele conta para a Casca de Coco
			if unit.Alive and unit.Hp > 0 then
				shellCount(state, unit)
			end
		end
	end

	-- 3. Fim do turno
	if unit.Alive then
		endTurn(state, unit)
	end
end

-- Um turno; o 1º de cada brainrot fica marcado enquanto dura (FirstTurnActive: Julgamento de Eyros, 14/11/2026)
local function takeTurn(state: State, unit: Unit)
	local holder = unit :: any
	holder.FirstTurnActive = not holder.TookTurn
	holder.TookTurn = true
	playTurn(state, unit)
	holder.FirstTurnActive = nil
	-- Casca de Coco: quem já levou os ataques do coco sai no fim deste turno (o ataque inteiro bate com a redução)
	for _, fighter in state.units do
		local shell = (fighter :: any).Shell
		if shell and fighter.Alive and shell.Hits >= shell.Need then
			shellLeave(state, fighter)
		end
	end
end

-- Quem age agora: o menor Next; empate → maior Velocidade atual → maior talento de Velocidade →
-- lados diferentes: sorteio no 1º empate e depois alterna → mesmo lado: a frente primeiro
local function pickNext(state: State): Unit?
	-- Sem Sinal (LowHpRush): quem pediu o próximo turno vai antes de todos (o Next dele já é a hora de agora)
	for _, unit in state.units do
		if unit.Alive and (unit :: any).Rush then
			return unit
		end
	end
	local minTime = math.huge
	for _, unit in state.units do
		if unit.Alive and unit.Next < minTime then
			minTime = unit.Next
		end
	end
	local top: { Unit } = {}
	local function better(a: Unit, b: Unit): boolean
		local speedA, speedB = speedOf(a), speedOf(b)
		if math.abs(speedA - speedB) > 1e-9 then
			return speedA > speedB
		end
		return a.SpdTalent > b.SpdTalent
	end
	for _, unit in state.units do
		if unit.Alive and unit.Next - minTime < CombatConfig.TieEpsilon then
			if #top == 0 or better(unit, top[1]) then
				top = { unit }
			elseif not better(top[1], unit) then
				table.insert(top, unit)
			end
		end
	end
	if #top <= 1 then
		return top[1]
	end
	local side = top[1].Side
	for _, unit in top do
		if unit.Side ~= side then
			if not state.tieSide then
				state.tieSide = if state.rng:NextInteger(0, 1) == 0 then "A" else "B"
			end
			side = state.tieSide :: string
			state.tieSide = other(side)
			break
		end
	end
	local chosen: Unit? = nil
	for _, unit in top do
		if unit.Side == side and (not chosen or unit.Pos < chosen.Pos) then
			chosen = unit
		end
	end
	return chosen
end

local function makeUnit(spec: UnitSpec, side: string, pos: number): Unit
	local species = SpeciesConfig.get(spec.Passive) or SpeciesConfig.get(spec.Species)
	local byType: { [string]: { Effect } } = {}
	if species then
		-- A passiva cresce com as estrelas de quem luta (PassivePower, 13/11/2026)
		for _, effect in PassivePower.effects(species, spec.Stars) do
			byType[effect.Type] = byType[effect.Type] or {}
			table.insert(byType[effect.Type], effect)
		end
	end
	for _, list in { spec.ExtraEffects or {}, spec.ArtifactEffects or {} } do
		for _, effect in list do
			byType[effect.Type] = byType[effect.Type] or {}
			table.insert(byType[effect.Type], effect)
		end
	end
	return {
		Key = side .. pos,
		Side = side,
		Pos = pos,
		MaxHp = math.max(1, spec.Stats.Hp),
		Hp = math.clamp(spec.StartHp or spec.Stats.Hp, 1, math.max(1, spec.Stats.Hp)),
		Atk = spec.Stats.Atk,
		Spd = spec.Stats.Spd,
		SpdTalent = spec.SpdTalent,
		MaxHpHitShare = spec.MaxHpHitShare,
		SuperBoss = spec.SuperBoss,
		Shield = 0,
		Alive = true,
		Next = 0,
		PassiveId = if species then species.Id else spec.Passive,
		PassiveName = if species then species.Passive.Name else "",
		Effects = byType,
		Stun = 0,
		Vulnerable = 0,
		StunImmune = false,
		Burn = nil,
		Debuffs = {},
		Fury = 0,
		Guard = 0,
		InitiativeTurns = 0,
		InitiativeBonus = 0,
		Attacks = 0,
		PendingBonus = 0,
		Revives = 0,
		LastAt = 0,
		ActionTime = CombatConfig.ActionTime,
	}
end

local function sideAlive(state: State, side: string): boolean
	return front(state, side) ~= nil
end

local function hpShare(state: State, side: string): number
	local hp, max = 0, 0
	for _, unit in state.sides[side] do
		max += unit.MaxHp
		if unit.Alive then
			hp += unit.Hp
		end
	end
	return if max > 0 then hp / max else 0
end

local function aliveCount(state: State, side: string): number
	local count = 0
	for _, unit in state.sides[side] do
		if unit.Alive then
			count += 1
		end
	end
	return count
end

-- Golpe de abertura (OpeningStrike, NUKE do Bombardiro; 13/11/2026, pedido do usuário): no 1º turno dele (era no início
-- da luta até 14/11/2026), um golpe de
-- Multiplier em TODOS os inimigos da luta (na Arena, de todos os outros times, perto ou longe). Com Every, a NUKE sai
-- de novo depois de cada Every ataques de quem tem (4º, 8º...; 13/11/2026, pedido do usuário)
local function nuke(state: State, unit: Unit, effect: any)
	local foes = {}
	for _, foe in state.units do
		if foe.Side ~= unit.Side and foe.Alive then
			table.insert(foes, foe)
		end
	end
	local first = true
	local wave = {}
	for _, foe in foes do
		if foe.Alive and unit.Alive then
			strike(state, unit, foe, "Extra", 1, {
				Multiplier = effect.Multiplier or 1,
				Passive = unit.PassiveName,
				Fx = effect.Fx,
				FxFirst = first,
				All = true,
				Wave = wave,
			})
			first = false
		end
	end
end

nukeAgain = nuke

-- Napalm de abertura (OpeningSnipe, Bombombini Gusini; 15/11/2026, pedido do usuário): ANTES do 1º turno de todos, voa
-- por cima do inimigo com MENOS Vida da luta (na Arena, de qualquer outro time) e solta um napalm só nele: Multiplier ×
-- o Ataque (golpe normal: pode esquivar e critar). Dois com a habilidade na luta: o mais rápido solta primeiro (e o
-- segundo já mira em quem tiver menos Vida depois do primeiro)
local function weakestFoe(state: State, unit: Unit): Unit?
	local best: Unit? = nil
	for _, foe in state.units do
		if foe.Side ~= unit.Side and foe.Alive and foe.Hp > 0 then
			if not best or foe.Hp < best.Hp or (foe.Hp == best.Hp and foe.Pos < best.Pos) then
				best = foe
			end
		end
	end
	return best
end

local function openingSnipes(state: State)
	local snipers: { Unit } = {}
	for _, unit in state.units do
		if effects(unit, "OpeningSnipe")[1] then
			table.insert(snipers, unit)
		end
	end
	table.sort(snipers, function(a, b)
		local speedA, speedB = speedOf(a), speedOf(b)
		if speedA ~= speedB then
			return speedA > speedB
		elseif a.SpdTalent ~= b.SpdTalent then
			return a.SpdTalent > b.SpdTalent
		end
		return a.Key < b.Key
	end)
	for _, unit in snipers do
		for _, effect in effects(unit, "OpeningSnipe") do
			local target = if unit.Alive and unit.Hp > 0 then weakestFoe(state, unit) else nil
			if target then
				strike(state, unit, target, "Extra", 1, {
					Multiplier = effect.Multiplier or 1,
					Passive = unit.PassiveName,
					Fx = effect.Fx,
				})
			end
		end
	end
end

-- Início da luta: Gravidade (Vaca Saturno) e o que vem da árvore de skills (Silent: escudo, arrancada) → primeiro Next.
-- As habilidades "de início" dos brainrots (escudo, escudo do time, Arrancada, NUKE) saem no 1º turno de cada um
-- (firstTurnSkills; 14/11/2026, pedido do usuário: estavam fortes demais; a Vaca ficou igual)
local function startBattle(state: State)
	for _, unit in state.units do
		-- Guarda do 1º golpe (Blueberrini, 18/11/2026): o escudo da redução de dano em cima dele até levar o 1º golpe
		-- (Quiet = só o ícone, sem texto subindo; some no Expire "DamageReduction" do strike)
		for _, effect in effects(unit, "FirstHitGuard") do
			emit(state, {
				T = "Status",
				U = unit.Key,
				Target = unit.Key,
				Status = "DamageReduction",
				Pct = effect.Percent or 0,
				Turns = 0,
				Quiet = true,
			})
		end
		-- Redução fixa (artefatos, habilidade, árvore; 20/11/2026, pedido do usuário): ícone do escudo a luta inteira
		-- Mesma conta do golpe (multiplica); só as que valem sempre (sem Chance ou Chance 1)
		local kept = 1
		for _, effect in effects(unit, "DamageReduction") do
			if (effect.Chance or 1) >= 1 then
				kept *= 1 - (effect.Percent or 0)
			end
		end
		local armor = 1 - kept
		if armor > 0 then
			emit(state, {
				T = "Status",
				U = unit.Key,
				Target = unit.Key,
				Status = "Armor",
				Pct = armor,
				Turns = 0,
				Quiet = true,
			})
		end
		-- Escudo (Músculo de Frappé e árvore) e escudo do time (Câmara Fria): antes de todos agirem (16/11/2026, pedido
		-- do usuário; de 14 a 16/11 saíam no 1º turno de cada um)
		for _, effect in effects(unit, "Shield") do
			addShield(state, unit, effect)
		end
		for _, effect in effects(unit, "TeamShield") do
			for _, ally in state.sides[unit.Side] do
				if ally.Alive then
					local base = if effect.OwnMaxHp then ally.MaxHp else unit.MaxHp
					ally.Shield += round((effect.Percent or 0) * base)
					emit(state, { T = "Shield", U = ally.Key, Amount = ally.Shield, Passive = unit.PassiveName })
				end
			end
		end
		for _, initiative in effects(unit, "Initiative") do
			-- AtStart (16/11/2026, pedido do usuário: Arrancada do Tracotucotulu): passiva que liga já no começo.
			-- 17/11/2026: todas somam (antes só a maior)
			if (initiative :: any).Silent or (initiative :: any).AtStart then
				startInitiative(state, unit, initiative)
			end
		end
	end
	for _, unit in state.units do
		for _, effect in effects(unit, "Debuff") do
			if effect.AtStart then
				local foes = if state.startFoes then state.startFoes(unit) else state.sides[other(unit.Side)]
				for _, foe in foes do
					applyDebuff(state, unit, foe, effect)
				end
				emit(state, {
					T = "Debuff",
					U = unit.Key,
					Targets = "All",
					Stat = effect.Stat,
					Pct = effect.Percent,
					Turns = debuffTurns(effect),
					Passive = unit.PassiveName,
				})
			end
		end
	end
	openingSnipes(state)
	-- Só a Arrancada de passiva (AtStart, sem Silent) sai na frente no tempo 0. A da árvore de skills (Patas ligeiras,
	-- Silent) só soma Velocidade (18/11/2026: fazia o time inteiro agir antes de qualquer inimigo, até de um 5x mais rápido)
	for _, unit in state.units do
		local first = false
		for _, initiative in effects(unit, "Initiative") do
			if (initiative :: any).AtStart and not (initiative :: any).Silent then
				first = true
			end
		end
		unit.Next = if first and unit.InitiativeTurns > 0 then 0 else intervalOf(unit)
	end
end

local function duration(events: { { [string]: any } }): number
	local total = CombatConfig.EventTime.Start
	for _, event in events do
		total += (CombatConfig.EventTime :: any)[event.T] or 0
	end
	return total
end

function BattleEngine.run(sideA: { UnitSpec }, sideB: { UnitSpec }, options: Options): Script
	local seed = options.Seed or Random.new():NextInteger(1, 2 ^ 31 - 1)
	local state: State = {
		rng = Random.new(seed),
		units = {},
		sides = { A = {}, B = {} },
		events = {},
		turns = 0,
		tieSide = nil,
	}
	local units = {}
	for side, specs in { A = sideA, B = sideB } do
		for pos, spec in specs do
			local unit = makeUnit(spec, side, pos)
			table.insert(state.sides[side], unit)
			units[unit.Key] = {
				Side = side,
				Pos = pos,
				Species = spec.Species,
				Passive = unit.PassiveId,
				PassiveName = unit.PassiveName,
				Level = spec.Level,
				Stars = spec.Stars,
				Mutation = spec.Mutation, -- Dourado (19/11/2026)
				MaxHp = unit.MaxHp,
				Hp = unit.Hp,
				Atk = unit.Atk,
				Spd = unit.Spd,
				Scale = spec.Scale or 1,
				Size = spec.Size, -- % de tamanho (balão de stats; 13/11/2026)
				Artifacts = spec.Artifacts, -- ids dos artefatos (balão de stats; 16/11/2026)
				BossName = spec.BossName,
			}
		end
	end
	-- Ordem fixa (A1, A2, A3, B1, B2, B3): o dicionário acima não garante ordem
	for _, side in { "A", "B" } do
		for _, unit in state.sides[side] do
			table.insert(state.units, unit)
		end
	end

	-- Aura na hora em que um inimigo cai (options.OnKill): número em cima dele e o level up de quem subiu
	if options.OnKill then
		local onKill = options.OnKill
		state.onDeath = function(dead: Unit)
			if dead.Side ~= "B" then
				return
			end
			local result = onKill(dead.Key)
			if not result then
				return
			end
			if result.Aura > 0 then
				emit(state, { T = "KillAura", U = dead.Key, Aura = result.Aura })
			end
			for _, unit in state.sides.A do
				local gain = result.Gains[unit.Key]
				if gain then
					local stats = gain.Stats
					if stats and unit.Alive then
						local grow = math.max(0, stats.Hp - unit.MaxHp)
						unit.MaxHp = math.max(unit.MaxHp, stats.Hp)
						unit.Hp = math.min(unit.MaxHp, unit.Hp + grow)
						unit.Atk = stats.Atk
						unit.Spd = stats.Spd
					end
					emit(state, {
						T = "LevelUp",
						U = unit.Key,
						Level = gain.Level,
						MaxHp = unit.MaxHp,
						Hp = if unit.Alive then unit.Hp else 0,
						Atk = unit.Atk,
						Spd = unit.Spd,
						Alive = unit.Alive or nil,
					})
				end
			end
		end
	end

	-- Morte súbita (CombatConfig.SuddenDeath; 14/11/2026): a partir do turno StartTurn o dano de todos sobe, em degraus
	local sudden = CombatConfig.SuddenDeath
	local suddenLevel = 0
	state.damageBonus = function(): number
		return 1 + suddenLevel * sudden.Bonus
	end

	startBattle(state)
	local winner, reason = "B", "KO"
	while true do
		if not sideAlive(state, "A") or not sideAlive(state, "B") then
			-- Os dois caíram juntos: perde o time que acabou primeiro (explosão do Bombombini depois da queda, 15/11/2026);
			-- no mesmo golpe (espinhos no último golpe), vence quem defende
			if sideAlive(state, "A") or sideAlive(state, "B") then
				winner = if sideAlive(state, "A") then "A" else "B"
			elseif state.emptiedFirst then
				winner = other(state.emptiedFirst)
			else
				winner = "B"
			end
			reason = "KO"
			break
		end
		if state.turns >= CombatConfig.MaxTurns then
			reason = "TurnLimit"
			local shareA, shareB = hpShare(state, "A"), hpShare(state, "B")
			if math.abs(shareA - shareB) > 1e-9 then
				winner = if shareA > shareB then "A" else "B"
			else
				winner = if aliveCount(state, "A") > aliveCount(state, "B") then "A" else "B"
			end
			break
		end
		local level = if state.turns >= sudden.StartTurn
			then math.floor((state.turns - sudden.StartTurn) / sudden.Every) + 1
			else 0
		if level > suddenLevel then
			suddenLevel = level
			emit(state, { T = "Overtime", Level = level, Pct = level * sudden.Bonus })
		end
		local unit = pickNext(state)
		if not unit then
			break
		end
		takeTurn(state, unit)
	end
	emit(state, { T = "End", Winner = winner, Reason = reason })

	local finalHp = {}
	for _, unit in state.units do
		finalHp[unit.Key] = if unit.Alive then unit.Hp else 0
	end
	return {
		Version = SCRIPT_VERSION,
		Seed = seed,
		Mode = options.Mode,
		Floor = options.Floor,
		Units = units,
		Events = state.events,
		Result = {
			Winner = winner,
			Reason = reason,
			Turns = state.turns,
			HpA = roundTo(hpShare(state, "A"), 3),
			HpB = roundTo(hpShare(state, "B"), 3),
			Duration = roundTo(duration(state.events), 1),
			FinalHp = finalHp,
		},
	}
end

-- Peças do motor para a Arena de 4 times (Server/Combat/ArenaEngine): as mesmas regras de golpe, com os ganchos do
-- estado no lugar da fila inimiga
BattleEngine.Core = {
	makeUnit = makeUnit,
	startBattle = startBattle,
	takeTurn = takeTurn,
	speedOf = speedOf,
	emit = emit,
	roundTo = roundTo,
}

return BattleEngine
]=]
SOURCES["src/server/Events/BrawlSkills.luau"] = [=[
--[[
	BrawlSkills — as habilidades (passivas de SpeciesConfig) valendo na briga do Coliseu, em tempo real.

	As mesmas regras da luta por turnos (Combat/BattleEngine), com "1 turno" = BrawlConfig.Skills.TurnSeconds.
	A Vida de briga vem do papel, então porcentagens de Vida usam a Vida de briga e os multiplicadores
	valem sobre o dano do papel. Só regras: quem desenha e guarda é o BrawlService, que passa o "ctx":

		ctx.rng                          → Random
		ctx.enemiesNear(unit, raio)      → brainrots inimigos de pé até esse raio
		ctx.allies(unit)                 → o time dele (inclusive ele)
		ctx.emit(unit, nome, fx?, golpe?) → avisa os clientes (nome da habilidade, efeito especial)
		ctx.changed(unit)                → a Vida mudou (guardar)
		ctx.onKo(quemBateu?, alvo)       → nocauteado
		ctx.onRevive(unit)               → usou a Revive (só uma vez até curar no terreno)

	Tipos: AttackPattern, AttackStacking, Burn, Crit, DamageReduction, Debuff, Dodge, ExtraAttack,
	HealPerTurn, Initiative, Lifesteal, Reflect, Revive, Shield, Stun, TeamHeal, TeamShield, TeamShieldEvery.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local ComboTiming = require(Shared.Brainrot.ComboTiming)
local BattleFxConfig = require(Shared.Config.BattleFxConfig)
local ArtifactConfig = require(Shared.Config.ArtifactConfig)
local BrawlConfig = require(Shared.Config.BrawlConfig)
local CombatConfig = require(Shared.Config.CombatConfig)
local SpeciesConfig = require(Shared.Config.SpeciesConfig)
local PassivePower = require(Shared.Brainrot.PassivePower)

local SKILLS = BrawlConfig.Skills

local BrawlSkills = {}

-- Za Warudo sai neste ataque? Com First (Lirilì; 13/11/2026, pedido do usuário): no 1º ataque e depois a cada Every
-- (1º, 5º, 9º... com Every 4); sem First: no Every-ésimo (4º, 8º...). Os golpes da própria habilidade não contam
local function timeStopFires(effect: any, attacks: number): boolean
	local every = effect.Every or 0
	if every <= 0 or attacks <= 0 then
		return false
	end
	return if effect.First then (attacks - 1) % every == 0 else attacks % every == 0
end

local function effects(unit: any, kind: string): { any }
	return unit.Effects[kind] or {}
end

local function roll(ctx: any, chance: number?): boolean
	return ctx.rng:NextNumber() < (chance or 1)
end

local function debuffFactor(unit: any, stat: string, now: number): number
	-- Lentidão (17/11/2026, igual ao BattleEngine): só a mais forte vale; as outras esperam o tempo delas
	local factor, strongest = 1, 0
	for _, debuff in unit.Debuffs do
		if debuff.Stat == stat and debuff.Until > now then
			if stat == "Spd" then
				strongest = math.max(strongest, debuff.Percent)
			else
				factor *= 1 - debuff.Percent
			end
		end
	end
	return math.max(SKILLS.MinStatFactor, factor * (1 - strongest))
end

-- Monta os campos das habilidades em um brainrot da briga (passiveId = id da espécie dona da passiva)
-- stars = estrelas do brainrot: a passiva cresce com elas (PassivePower, 13/11/2026)
function BrawlSkills.attach(
	unit: any,
	passiveId: string,
	revivesUsed: number,
	artifactEffects: { any }?,
	stars: number?
)
	local species = SpeciesConfig.get(passiveId)
	local passive = species and species.Passive
	local grouped: { [string]: { any } } = {}
	for _, effect in if species then PassivePower.effects(species, stars) else {} do
		grouped[effect.Type] = grouped[effect.Type] or {}
		table.insert(grouped[effect.Type], effect)
	end
	for _, effect in artifactEffects or {} do
		grouped[effect.Type] = grouped[effect.Type] or {}
		table.insert(grouped[effect.Type], effect)
	end
	unit.PassiveId = passiveId
	unit.PassiveName = if passive then passive.Name else ""
	unit.PassiveFx = passive and passive.Fx
	unit.Effects = grouped
	unit.Attacks = unit.Attacks or 0
	unit.Fury = unit.Fury or 0
	unit.Shield = unit.Shield or 0
	unit.PendingBonus = unit.PendingBonus or 0
	unit.StunUntil = unit.StunUntil or 0
	unit.StunImmuneUntil = unit.StunImmuneUntil or 0
	unit.Vulnerable = unit.Vulnerable or 0
	unit.Debuffs = unit.Debuffs or {}
	unit.Queue = unit.Queue or {}
	unit.Revives = revivesUsed
	unit.InitiativeHits = unit.InitiativeHits or 0
	unit.HealTimer = unit.HealTimer or 0
	unit.BurnUntil = unit.BurnUntil or 0
	unit.BurnPercent = unit.BurnPercent or 0
	unit.BurnTimer = unit.BurnTimer or 0
end

-- Velocidade para andar e bater
-- Segundos até o próximo ataque: a mesma reta da Arena pela Velocidade do brainrot (unit.Spd, posto pelo
-- BrawlService) × lentidão/SpdUp (13/11/2026, pedido do usuário; antes era o Interval do papel ÷ esses efeitos)
function BrawlSkills.attackInterval(unit: any, now: number): number
	return CombatConfig.attackInterval(
		(unit.Spd or CombatConfig.RealtimeAttack.Low.Spd) * BrawlSkills.speedFactor(unit, now)
	)
end

function BrawlSkills.speedFactor(unit: any, now: number): number
	local bonus = 0
	if unit.InitiativeHits > 0 then
		local initiative = effects(unit, "Initiative")[1]
		bonus = if initiative then initiative.SpeedBonus or 0 else 0
	end
	return debuffFactor(unit, "Spd", now) * (1 + bonus)
end

-- Ícones de status do brainrot na briga (16/11/2026; ids do StatusConfig, iguais aos da luta por turnos). Turns = turnos
-- de briga que faltam (TurnSeconds cada), 0 = sem fim
function BrawlSkills.statusOf(unit: any, now: number): { { Id: string, Percent: number, Turns: number } }
	local list = {}
	local function add(id: string, percent: number, untilTime: number?, inactive: boolean?)
		local turns = if untilTime then math.max(1, math.ceil((untilTime - now) / SKILLS.TurnSeconds)) else 0
		table.insert(
			list,
			{ Id = id, Percent = math.floor(percent * 100 + 0.5) / 100, Turns = turns, Inactive = inactive }
		)
	end
	if (unit.Fury or 0) > 0 then
		add("AtkUp", unit.Fury)
	end
	if (unit.InitiativeHits or 0) > 0 then
		local initiative = effects(unit, "Initiative")[1]
		if initiative and (initiative.SpeedBonus or 0) > 0 then
			add("SpdUp", initiative.SpeedBonus)
		end
	end
	if (unit.StunUntil or 0) > now then
		add("Stun", 0, unit.StunUntil)
	end
	if (unit.BurnUntil or 0) > now then
		add("Burn", unit.BurnPercent or 0, unit.BurnUntil)
	end
	local worst: { [string]: any } = {}
	for _, debuff in unit.Debuffs or {} do
		if debuff.Until > now and (not worst[debuff.Stat] or debuff.Percent > worst[debuff.Stat].Percent) then
			worst[debuff.Stat] = debuff
		end
	end
	if worst.Atk then
		add("AtkDown", worst.Atk.Percent, worst.Atk.Until)
	end
	-- Lentidão (17/11/2026): um ícone por fonte; só a mais forte vale, as outras apagadas esperando
	local slows = {}
	for _, debuff in unit.Debuffs or {} do
		if debuff.Stat == "Spd" and debuff.Until > now then
			table.insert(slows, debuff)
		end
	end
	table.sort(slows, function(a, b)
		return a.Percent > b.Percent
	end)
	for index, debuff in slows do
		add("SpdDown", debuff.Percent, debuff.Until, index > 1 or nil)
	end
	return list
end

function BrawlSkills.isStunned(unit: any, now: number): boolean
	return unit.StunUntil > now
end

function BrawlSkills.isBurning(unit: any, now: number): boolean
	return unit.BurnUntil > now
end

local function heal(ctx: any, unit: any, amount: number)
	if unit.Ko or amount <= 0 or unit.Hp >= unit.MaxHp then
		return
	end
	unit.Hp = math.min(unit.MaxHp, unit.Hp + amount)
	ctx.changed(unit)
end

-- Maçã (artefato): conta os golpes que acertaram, dados ou levados; a cada Every, cura Percent da Vida máxima
-- Com Dealt (Trulimero, 14/11/2026): só os golpes que ELE deu contam. dealt = este golpe foi dele
local function countHit(ctx: any, unit: any, dealt: boolean)
	local list = effects(unit, "HealEveryHits")
	if #list == 0 then
		return
	end
	unit.HitCount = (unit.HitCount or 0) + 1
	if dealt then
		unit.DealtCount = (unit.DealtCount or 0) + 1
	end
	for _, effect in list do
		local count = if effect.Dealt then (if dealt then unit.DealtCount else 0) else unit.HitCount
		if (effect.Every or 0) > 0 and count > 0 and count % effect.Every == 0 and not unit.Ko then
			heal(ctx, unit, (effect.Percent or 0) * unit.MaxHp)
			ctx.emit(unit, effect.Name or unit.PassiveName, if effect.Name then "ArtifactHeal" else "Heal")
		end
	end
end

-- Tira Vida (o escudo absorve antes); cuida da Revive e do nocaute. Roubo de vida de quem causou vale em TODO dano
-- (14/11/2026, pedido do usuário): golpe, Jakalopita, Julgamento, espinhos, escudo que explode e queimadura
-- Penetração (Chamas de Goes, efeito Pierce; 15/11/2026), igual ao motor: soma do campo de quem bate, até 100%
local function pierceOf(unit: any, field: string): number
	local total = 0
	for _, effect in effects(unit, "Pierce") do
		total += effect[field] or 0
	end
	return math.min(1, total)
end

local function damage(ctx: any, source: any?, target: any, amount: number)
	if source and source ~= target and not source.Ko and amount > 0 then
		for _, effect in effects(source, "Lifesteal") do
			heal(ctx, source, (effect.Percent or 0) * amount)
		end
	end
	-- Escudo (07/11/2026): com qualquer escudo, o golpe inteiro bate só nele (o que sobra se perde)
	-- Penetração de escudo de quem bateu (Chamas de Goes, 16/11/2026, pedido do usuário): esta fração do golpe vai
	-- direto na Vida, o resto bate no escudo (40% = 40% na Vida e 60% no escudo)
	local absorbed = if target.Shield > 0 then amount else 0
	if absorbed > 0 then
		local pierce = if source and source ~= target then pierceOf(source, "ShieldPierce") else 0
		absorbed = amount * (1 - pierce)
		target.Shield = math.max(0, target.Shield - absorbed)
	end
	target.Hp -= amount - absorbed
	if target.Hp <= 0 then
		local revive = effects(target, "Revive")[1]
		if revive and target.Revives < (revive.Uses or 1) then
			target.Revives += 1
			target.Hp = math.max(1, (revive.Percent or 0) * target.MaxHp)
			target.BurnUntil = 0
			target.StunUntil = 0
			table.clear(target.Debuffs)
			target.Vulnerable = 0
			target.Fury += revive.Fury or 0
			ctx.onRevive(target)
			ctx.emit(target, target.PassiveName)
		else
			target.Hp = 0
			target.Ko = true
			target.Queue = {}
			ctx.onKo(source, target)
		end
	end
	ctx.changed(target)
	if target.Ko or target.Hp <= 0 then
		return
	end
	-- Levou dano e está de pé (13/11/2026, igual ao motor, BattleEngine onHurt):
	--   HurtCharge (Pirueta): o próximo ataque dá Multiplier o dano
	--   LowHpRush (Sem Sinal): a Vida caiu abaixo de uma marca (Thresholds) → o tempo do ataque recomeça do zero
	for _, effect in effects(target, "HurtCharge") do
		local multiplier = effect.Multiplier or 1
		if multiplier > (target.Charged or 1) then
			target.Charged = multiplier
		end
	end
	for _, effect in effects(target, "LowHpRush") do
		target.RushCrossed = target.RushCrossed or {}
		-- Na briga a Vida fica guardada entre as entradas: marca que a Vida voltou a passar (cura) fica pronta de novo
		if PassivePower.crossThresholds(effect, target.RushCrossed, target.Hp / target.MaxHp, true) then
			target.Cooldown = 0
			ctx.emit(target, target.PassiveName, target.PassiveFx)
		end
	end
end

local function tryStun(ctx: any, source: any, target: any, turns: number, now: number, vulnerable: number?)
	if target.StunImmuneUntil > now or target.Ko then
		return
	end
	target.Vulnerable = vulnerable or 0
	local seconds = turns * SKILLS.TurnSeconds
	target.StunUntil = now + seconds
	target.StunImmuneUntil = now + seconds + SKILLS.StunImmuneSeconds
	ctx.emit(source, source.PassiveName)
end

local function addDebuff(ctx: any, source: any, target: any, effect: any, now: number): boolean
	local key = `{source.PassiveId}:{effect.Stat or "Atk"}`
	-- Nada dura para sempre (12/11/2026, CombatConfig.MinDebuffTurns)
	local turns = math.max(CombatConfig.MinDebuffTurns, math.floor(tonumber(effect.Turns) or 0))
	local untilTime = now + turns * SKILLS.TurnSeconds
	local existing = target.Debuffs[key]
	if existing and existing.Until >= untilTime then
		return false
	end
	target.Debuffs[key] = { Stat = effect.Stat or "Atk", Percent = effect.Percent or 0, Until = untilTime }
	ctx.emit(source, source.PassiveName)
	return true
end

local function onHit(ctx: any, attacker: any, target: any, stunTurns: number?, now: number)
	if stunTurns and stunTurns > 0 then
		tryStun(ctx, attacker, target, stunTurns, now)
	end
	for _, effect in effects(attacker, "Stun") do
		if roll(ctx, effect.Chance) then
			tryStun(ctx, attacker, target, effect.Turns or 1, now, effect.Vulnerable)
		end
	end
	for _, effect in effects(attacker, "Burn") do
		if roll(ctx, effect.Chance) then
			target.BurnUntil = now + (effect.Turns or 1) * SKILLS.TurnSeconds
			target.BurnPercent = effect.Percent or 0
			target.BurnSource = attacker
			ctx.emit(attacker, attacker.PassiveName)
		end
	end
	for _, effect in effects(attacker, "Debuff") do
		if not effect.AtStart and roll(ctx, effect.Chance) then
			addDebuff(ctx, attacker, target, effect, now)
		end
	end
end

type StrikeOptions = {
	Multiplier: number?,
	ForcedCrit: number?,
	StunTurns: number?,
	Push: boolean?,
	NoReaction: boolean?, -- contra-ataque: não pode ser esquivado nem aplica efeitos
	Basic: boolean?, -- ataque básico (não é passo de habilidade): o que o RetaliateDebuff do alvo responde
	Wave: {}?, -- o mesmo golpe em área (todos os alvos dele): o Julgamento de Eyros sai em todos, com 33%
}

local riposte: (any, any, any, number) -> ()

-- Velocidade das habilidades (19/11/2026, pedido do usuário): até 1 ataque/s = 1; acima disso as pancadas e as
-- animações aceleram na mesma proporção (2 ataques/s = 2x). O cliente recebe no BrawlSkill (BrawlController)
function BrawlSkills.animRate(unit: any, now: number): number
	return math.max(1, 1 / BrawlSkills.attackInterval(unit, now))
end

-- Segundos depois do começo do golpe em que a pancada `hit` acerta. Pulo na Cabeça (Fx "HeadJump", Chimpanzini): cada
-- pulo cai a Seconds/Hops do anterior, e o dano sai quando ele TOCA o alvo, inclusive no 1º (13/11/2026: o 1º saía
-- quando o pulo começava); os outros, no ritmo das animações (ComboTiming)
local function hitDelay(unit: any, step: any?, hit: number): number
	if step and step.Fx == "HeadJump" then
		local jump = BattleFxConfig.HeadJump
		return hit * jump.Seconds / jump.Hops
	end
	return ComboTiming.offset(unit.Species or "", hit) / BrawlSkills.animRate(unit, os.clock())
end

-- Casca de Coco: conta um golpe dado ou levado (definida perto do attack)
local shellCount: (any, any, number, any?) -> ()

local function strike(ctx: any, attacker: any, target: any, now: number, options: StrikeOptions)
	if attacker.Ko or target.Ko then
		return
	end
	-- Enfraquecimento "de início da luta": vale do primeiro golpe em cada inimigo em diante
	for _, effect in effects(attacker, "Debuff") do
		if effect.AtStart then
			addDebuff(ctx, attacker, target, effect, now)
		end
	end
	if not options.NoReaction then
		-- Esquiva garantida do 1º golpe (Golpe Ninja): um crítico dele deixa pronta de novo (até Recharges vezes)
		if effects(target, "FirstDodge")[1] and not target.FirstDodgeSpent then
			target.FirstDodgeSpent = true
			ctx.emit(target, target.PassiveName, "Dodge")
			riposte(ctx, target, attacker, now)
			return
		end
		for _, dodge in effects(target, "Dodge") do
			if roll(ctx, dodge.Chance) then
				ctx.emit(target, target.PassiveName, "Dodge")
				if dodge.NextAttackBonus then
					target.PendingBonus = dodge.NextAttackBonus
				end
				if dodge.CounterPercent then
					strike(ctx, target, attacker, now, { Multiplier = dodge.CounterPercent, NoReaction = true })
				end
				riposte(ctx, target, attacker, now)
				return
			end
		end
	end

	local role = BrawlConfig.Roles[attacker.Role]
	local factor = math.clamp(
		(attacker.Power / math.max(1, target.Power)) ^ BrawlConfig.PowerExponent,
		BrawlConfig.PowerMin,
		BrawlConfig.PowerMax
	)
	-- Um sorteio só, chances somadas (20/11/2026, igual ao BattleEngine)
	local critChance, critMultiplier, critNamed = BrawlConfig.CritChance, BrawlConfig.CritMultiplier, false
	for _, effect in effects(attacker, "Crit") do
		critChance += effect.Chance or 0
		critMultiplier = math.max(critMultiplier, effect.Multiplier or BrawlConfig.CritMultiplier)
		critNamed = critNamed or (effect.Chance or 0) > 0
	end
	local crit, critByPassive = 1, false
	if critChance >= 1 or roll(ctx, critChance) then
		crit, critByPassive = critMultiplier, critNamed
	end
	if options.ForcedCrit and options.ForcedCrit > crit then
		crit, critByPassive = options.ForcedCrit, true
	end
	for _, effect in effects(attacker, "Execute") do
		local multiplier = effect.Multiplier or 1
		if target.Hp <= (effect.Threshold or 0) * target.MaxHp and multiplier > crit then
			crit, critByPassive = multiplier, true
		end
	end
	if critByPassive then
		ctx.emit(attacker, attacker.PassiveName)
	end
	if crit > 1 then
		for _, effect in effects(attacker, "FirstDodge") do
			if
				attacker.FirstDodgeSpent
				and (effect.Recharges == nil or (attacker.FirstDodgeRecharges or 0) < effect.Recharges)
			then
				attacker.FirstDodgeSpent = false
				attacker.FirstDodgeRecharges = (attacker.FirstDodgeRecharges or 0) + 1
			end
		end
	end
	local reduction = 1
	for _, effect in effects(target, "DamageReduction") do
		if roll(ctx, effect.Chance) then
			reduction *= 1 - (effect.Percent or 0)
		end
	end
	-- Guarda do 1º golpe (FirstHitGuard, Blueberrini; 18/11/2026, igual ao motor): redução até levar o 1º golpe
	local guardHit = not target.FirstHitTaken and effects(target, "FirstHitGuard")[1] ~= nil
	if guardHit then
		target.FirstHitTaken = true
		for _, effect in effects(target, "FirstHitGuard") do
			reduction *= 1 - (effect.Percent or 0)
		end
	end
	-- Penetração de redução de dano (Chamas de Goes): tira esta fração da redução que sobrou depois do teto
	local guarded = math.max(1 - CombatConfig.MaxDamageReduction, reduction) -- teto universal de 90% (15/11/2026)
	guarded += (1 - guarded) * pierceOf(attacker, "ReductionPierce")
	local variation = ctx.rng:NextNumber(BrawlConfig.Variation[1], BrawlConfig.Variation[2])
	local amount = role.Damage
		* factor
		* variation
		* crit
		* guarded
		* (options.Multiplier or 1)
		* (1 + attacker.Fury)
		* debuffFactor(attacker, "Atk", now)
		* (if target.StunUntil > now then 1 + target.Vulnerable else 1)
	-- Espinhos são pré-mitigação (18/11/2026, pedido do usuário): contam sobre o golpe sem a redução de dano do alvo
	local unreduced = if guarded > 0 then amount / guarded else amount
	local hpBefore = target.Hp -- espinhos devolvem no máximo isto (07/11/2026)
	local hadShield = target.Shield > 0
	damage(ctx, attacker, target, amount)
	-- Crítico (16/11/2026, pedido do usuário): a tela mostra o número laranja com o ícone (aviso "Crit" no ALVO, com a
	-- Vida que ele perdeu de verdade; o escudo que segurou tudo não conta). Golpe que derruba não tem número
	if crit > 1 and not target.Ko then
		local lost = hpBefore - target.Hp
		if lost >= 1 then
			ctx.emit(target, "", "Crit", math.floor(lost + 0.5))
		end
	end
	-- Jakalopita (artefato, MaxHpHit; 13/11/2026): mais Percent da Vida máxima do alvo, à parte; a tela mostra o número
	-- roxo pelo aviso "MaxHpHit" (emit no ALVO, com o valor no lugar do golpe)
	if not target.Ko then
		local share = 0
		for _, effect in effects(attacker, "MaxHpHit") do
			share += effect.Percent or 0
		end
		if share > 0 then
			local extra = math.max(1, share * target.MaxHp)
			damage(ctx, attacker, target, extra)
			ctx.emit(target, "", "MaxHpHit", math.floor(extra + 0.5))
		end
	end
	-- Julgamento de Eyros (artefato, FirstStrike; 14/11/2026): durante o 1º "turno" deste brainrot na briga (um
	-- TurnSeconds a partir do 1º golpe dele, FirstStrikeAt), todo golpe tira mais Percent × o dano base dele, à parte;
	-- número amarelo pelo aviso "FirstStrike". Ataque básico num alvo só: inteiro; habilidade ou área: FirstStrikeAreaShare
	attacker.FirstStrikeAt = attacker.FirstStrikeAt or now
	if not target.Ko and now - attacker.FirstStrikeAt <= SKILLS.TurnSeconds then
		local share = 0
		for _, effect in effects(attacker, "FirstStrike") do
			share += effect.Percent or 0
		end
		if share > 0 then
			local full = options.Basic == true and options.Wave == nil
			local efficacy = if full then 1 else ArtifactConfig.FirstStrikeAreaShare
			local extra = math.max(1, share * efficacy * role.Damage)
			damage(ctx, attacker, target, extra)
			ctx.emit(target, "", "FirstStrike", math.floor(extra + 0.5))
		end
	end

	if options.Push then
		local away = target.Position - attacker.Position
		away = Vector3.new(away.X, 0, away.Z)
		local direction = if away.Magnitude > 0.01
			then away.Unit
			else Vector3.new(ctx.rng:NextNumber(-1, 1), 0, ctx.rng:NextNumber(-1, 1) + 0.01).Unit
		local studs = BrawlConfig.PushStuds
			* math.clamp(factor, BrawlConfig.PushMin, BrawlConfig.PushMax)
			* (if crit > 1 then 2 else 1)
		target.Velocity = direction * (studs / BrawlConfig.PushTime)
		target.PushUntil = now + BrawlConfig.PushTime
	end

	-- Espinhos: devolvem uma parte do dano recebido, em TODO golpe (até revide e contra-ataque; 07/11/2026). É dano direto (não é golpe): não ativa os espinhos de quem
	-- levou de volta, senão os dois ficariam se rebatendo para sempre
	for _, effect in effects(target, "Reflect") do
		if not attacker.Ko then
			local percent = effect.Percent or 0
			if percent > 0 then
				-- sempre pelo menos 1 e no máximo a Vida que ele tinha antes do golpe (07/11/2026)
				local thorns = math.max(1, math.min(percent * unreduced, hpBefore))
				-- Espinhos passam pela redução de dano de quem bateu (19/11/2026, pedido do usuário; teto de 90%)
				local kept = 1
				for _, guard in effects(attacker, "DamageReduction") do
					if (guard.Chance or 1) >= 1 then
						kept *= 1 - (guard.Percent or 0)
					end
				end
				thorns = math.max(1, thorns * math.max(1 - CombatConfig.MaxDamageReduction, kept))
				damage(ctx, target, attacker, thorns)
				ctx.emit(target, target.PassiveName, "ThornBurst")
				-- O número laranja em quem bateu (15/11/2026, como o "MaxHpHit": no ALVO dos espinhos, com o valor)
				ctx.emit(attacker, "", "Thorns", math.floor(thorns + 0.5))
			end
		end
	end
	countHit(ctx, attacker, true)
	countHit(ctx, target, false)
	-- Levou um golpe: conta para a Casca de Coco (Burbaloni) e pode entrar no coco na hora
	shellCount(ctx, target, now, attacker)
	-- Guarda do 1º golpe: de pé, revida (Multiplier × um golpe normal dele) e atordoa quem bateu por StunTurns turnos
	if guardHit and not target.Ko and not attacker.Ko then
		for _, effect in effects(target, "FirstHitGuard") do
			strike(ctx, target, attacker, now, { Multiplier = effect.Multiplier or 1, NoReaction = true })
			if (effect.StunTurns or 0) > 0 and not attacker.Ko then
				tryStun(ctx, target, attacker, effect.StunTurns, now)
			end
		end
	end
	if not options.NoReaction then
		-- Escudo que estoura pode explodir em quem quebrou
		if hadShield and target.Shield <= 0 and not attacker.Ko then
			for _, effect in effects(target, "Shield") do
				if (effect.BreakHpDamage or 0) > 0 then
					damage(ctx, target, attacker, (effect.BreakHpDamage or 0) * target.MaxHp)
					ctx.emit(target, target.PassiveName)
				end
			end
		end
		if not target.Ko then
			onHit(ctx, attacker, target, options.StunTurns, now)
			for _, effect in effects(target, "Trap") do
				if not attacker.Ko and roll(ctx, effect.Chance) then
					tryStun(ctx, target, attacker, effect.Turns or 1, now)
				end
			end
		end
		-- Ataque básico nele: quem bateu leva o enfraquecimento (RetaliateDebuff; Patapim, 14/11/2026)
		if options.Basic and not attacker.Ko then
			for _, effect in effects(target, "RetaliateDebuff") do
				if roll(ctx, effect.Chance or 1) then
					addDebuff(ctx, target, attacker, effect, now)
				end
			end
		end
	end
end

-- Revide de quem esquivou (DodgeRiposte, Cappuccino Assassino): na briga não há Ataque, então é um golpe de
-- Multiplier × um golpe normal dele (sem reação)
riposte = function(ctx: any, dodger: any, attacker: any, now: number)
	for _, effect in effects(dodger, "DodgeRiposte") do
		-- Limit = revides por luta (16/11/2026); a esquiva continua depois disso
		if effect.Limit and (dodger.RipostesUsed or 0) >= effect.Limit then
			continue
		end
		dodger.RipostesUsed = (dodger.RipostesUsed or 0) + 1
		strike(ctx, dodger, attacker, now, { Multiplier = effect.Multiplier or 1, NoReaction = true })
		-- 17/11/2026 (igual ao BattleEngine): o parry paralisa quem levou o revide
		if (effect.StunTurns or 0) > 0 and not attacker.Ko then
			tryStun(ctx, dodger, attacker, effect.StunTurns, now)
		end
	end
end

-- Igual ao motor (BattleEngine extraFires): com Every, garantido no 1º ataque e a cada Every; sem, sorteio de Chance
-- 15/11/2026 (pedido do usuário): o de Every é a habilidade do turno, no lugar do golpe (everyExtra); aqui só o de Chance
local function extraFires(ctx: any, _unit: any, effect: any, _before: boolean, _count: number): boolean
	if effect.Every then
		return false
	end
	return roll(ctx, effect.Chance)
end

-- Onda de Every (Orcalero): no 1º ataque e depois a cada Every, NO LUGAR do golpe. deal = golpe na piñata (bagAttack)
local function everyExtra(ctx: any, unit: any, target: any?, now: number, deal: ((number) -> ())?): boolean
	local fired = false
	for _, effect in effects(unit, "ExtraAttack") do
		if effect.Every and (unit.Attacks - 1) % effect.Every == 0 then
			fired = true
			ctx.emit(unit, unit.PassiveName, effect.Fx)
			if deal then
				deal(effect.Multiplier or 1)
			elseif effect.AllTargets then
				local wave = {}
				for _, foe in ctx.enemiesNear(unit, SKILLS.AreaRadius) do
					strike(ctx, unit, foe, now, { Multiplier = effect.Multiplier or 1, Wave = wave })
				end
			elseif target then
				strike(ctx, unit, target, now, { Multiplier = effect.Multiplier or 1 })
			end
		end
	end
	return fired
end

-- Fúria (AttackStacking): +PerTurn a cada ataque, até Max
local function stackFury(ctx: any, unit: any)
	for _, effect in effects(unit, "AttackStacking") do
		local before = unit.Fury
		unit.Fury = math.min(effect.Max or 0, unit.Fury + (effect.PerTurn or 0))
		if unit.Fury > before then
			ctx.emit(unit, unit.PassiveName)
		end
	end
end

-- Za Warudo: na briga, golpes seguidos que o alvo não consegue esquivar; NO LUGAR do golpe (15/11/2026). deal = piñata
local function zaWarudo(ctx: any, unit: any, target: any?, deal: ((number) -> ())?): boolean
	local fired = false
	for _, effect in effects(unit, "TimeStop") do
		if timeStopFires(effect, unit.Attacks) and (deal or (target and not target.Ko)) then
			fired = true
			ctx.emit(unit, unit.PassiveName, "TimeStop")
			-- AllTargets (Lirilì; 13/11/2026): na briga, todo brainrot inimigo de pé no Coliseu
			local victims = if deal
				then {}
				elseif (effect :: any).AllTargets then ctx.enemiesNear(unit, math.huge)
				else { target }
			-- 13/11/2026 (pedido do usuário): o 1º golpe 0,5 s depois do grito e os outros a cada 0,25 s
			-- (CombatConfig.TimeStopHits); todos os alvos juntos em cada golpe
			local timing = CombatConfig.TimeStopHits
			for action = 1, effect.Actions or 1 do
				task.delay(timing.Delay + (action - 1) * timing.Gap, function()
					if unit.Ko then
						return
					end
					if deal then
						deal(effect.Multiplier or 1)
						return
					end
					local wave = {}
					for _, victim in victims do
						if not victim.Ko then
							strike(
								ctx,
								unit,
								victim,
								os.clock(),
								{ Multiplier = effect.Multiplier or 1, NoReaction = true, Wave = wave }
							)
						end
					end
				end)
			end
		end
	end
	return fired
end

local function extraAttacks(ctx: any, unit: any, target: any, before: boolean, now: number)
	for _, effect in effects(unit, "ExtraAttack") do
		local count = 0
		while
			(effect.Before == true) == before
			and count < (effect.Chain or 1)
			and extraFires(ctx, unit, effect, before, count)
		do
			count += 1
			if effect.AllTargets then
				ctx.emit(unit, unit.PassiveName, effect.Fx)
				local wave = {}
				for _, foe in ctx.enemiesNear(unit, SKILLS.AreaRadius) do
					strike(ctx, unit, foe, now, { Multiplier = effect.Multiplier or 1, Wave = wave })
				end
			else
				ctx.emit(unit, unit.PassiveName, effect.Fx)
				strike(ctx, unit, target, now, { Multiplier = effect.Multiplier or 1 })
			end
		end
	end
end

local function patternStep(unit: any): any?
	local effect = effects(unit, "AttackPattern")[1]
	local pattern = effect and effect.Pattern
	if not pattern then
		return nil
	end
	if effect.Repeat then
		return pattern[((unit.Attacks - 1) % #pattern) + 1]
	end
	return pattern[unit.Attacks]
end

-- A vez do brainrot atacar: igual a uma ação da luta por turnos
-- Casca de Coco (CocoShell, Burbaloni; 19/11/2026, igual ao motor): depois de Every golpes somando os que deu e os que
-- levou, entra no coco por Turns × TurnSeconds, sem atacar, com Percent de redução e Thorns de espinhos (efeitos na
-- lista do próprio brainrot). shellBlocks: true = não ataca agora; a saída é vista na próxima tentativa de ataque
local function shellBlocks(ctx: any, unit: any, _now: number): boolean
	local shell = unit.Shell
	if not shell then
		return false
	end
	if shell.Hits < shell.Need then
		return true
	end
	unit.Shell = nil
	unit.ShellCount = 0
	for kind, effect in shell.Added do
		local list = unit.Effects[kind]
		local index = list and table.find(list, effect)
		if index then
			table.remove(list, index)
		end
	end
	ctx.emit(unit, "", "CocoShellOut")
	return false
end

shellCount = function(ctx: any, unit: any, now: number, attacker: any?)
	local effect = effects(unit, "CocoShell")[1]
	local shell = unit.Shell
	if shell then
		-- 19/11/2026 (pedido do usuário): dentro do coco, cada ATAQUE levado conta uma vez (golpes do mesmo atacante no
		-- mesmo instante, ex.: rajada do Bobrito, = 1). Need ataques → sai na próxima vez dele (shellBlocks)
		if attacker and (shell.LastBy ~= attacker or shell.LastAt ~= now) then
			shell.LastBy, shell.LastAt = attacker, now
			shell.Hits += 1
		end
		return
	end
	if not effect or unit.Ko then
		return
	end
	unit.ShellCount = (unit.ShellCount or 0) + 1
	if unit.ShellCount < (effect.Every or 2) then
		return
	end
	unit.ShellCount = 0
	local added = {
		DamageReduction = { Type = "DamageReduction", Percent = effect.Percent or 0, Chance = 1, Silent = true },
		Reflect = { Type = "Reflect", Percent = effect.Thorns or 0, Silent = true },
	}
	for kind, extra in added do
		unit.Effects[kind] = unit.Effects[kind] or {}
		table.insert(unit.Effects[kind], extra)
	end
	unit.Shell = { Hits = 0, Need = math.max(1, effect.Turns or 2), LastBy = nil, LastAt = now, Added = added }
	ctx.emit(unit, unit.PassiveName, "CocoShellIn") -- "CocoShell" sozinho é o efeito genérico da passiva (PassiveFx)
end

local function attackTurn(ctx: any, unit: any, target: any, now: number)
	extraAttacks(ctx, unit, target, true, now)
	if unit.Ko then
		return
	end

	unit.Attacks += 1
	for _, effect in effects(unit, "TeamShieldEvery") do
		if unit.Attacks % (effect.Every or 1) == 0 then
			for _, ally in ctx.allies(unit) do
				if not ally.Ko then
					ally.Shield += (effect.Percent or 0) * (if effect.OwnMaxHp then ally.MaxHp else unit.MaxHp)
				end
			end
			ctx.emit(unit, unit.PassiveName, "Shield")
		end
	end
	for _, effect in effects(unit, "TeamHeal") do
		if unit.Attacks % (effect.Every or 1) == 0 then
			local worst = nil
			for _, ally in ctx.allies(unit) do
				if
					not ally.Ko
					and ally.Hp < ally.MaxHp
					and (not worst or ally.Hp / ally.MaxHp < worst.Hp / worst.MaxHp)
				then
					worst = ally
				end
			end
			if worst then
				heal(ctx, worst, (effect.Percent or 0) * unit.MaxHp)
				ctx.emit(unit, unit.PassiveName, "Heal")
			end
		end
	end

	-- Turno de habilidade (15/11/2026, pedido do usuário): Za Warudo e onda de Every SÃO o ataque, no lugar do golpe
	if zaWarudo(ctx, unit, target) or everyExtra(ctx, unit, target, now) then
		stackFury(ctx, unit)
		local interval = BrawlSkills.attackInterval(unit, now)
		if unit.InitiativeHits > 0 then
			unit.InitiativeHits -= 1
		end
		unit.Cooldown = interval + hitDelay(unit, nil, 1)
		unit.Hitting = true
		return
	end

	local step = patternStep(unit)
	local special = step ~= nil and next(step) ~= nil
	local bonus = unit.PendingBonus
	unit.PendingBonus = 0
	-- Pirueta (HurtCharge): levou dano antes → este ataque dá Charged o dano
	local charge = unit.Charged or 1
	unit.Charged = nil
	if charge > 1 and not special then
		ctx.emit(unit, unit.PassiveName)
	end
	local hits = if step and step.Hits then step.Hits else 1
	local baseMultiplier = (1 + bonus) * charge
	local forcedCrit = nil
	if step then
		if step.Crit then
			forcedCrit = step.Multiplier or BrawlConfig.CritMultiplier
		else
			baseMultiplier *= step.Multiplier or 1
		end
	end
	if special then
		ctx.emit(
			unit,
			unit.PassiveName,
			step and step.Fx,
			if step and step.Fx then 1 else nil,
			target.Position -- no chão, embaixo do alvo (07/11/2026)
		)
	end
	local multiplier = baseMultiplier
	if step and step.FinalMultiplier and hits == 1 then
		multiplier *= step.FinalMultiplier
	end
	if step and step.AllTargets then
		local wave = {}
		for _, foe in ctx.enemiesNear(unit, SKILLS.AreaRadius) do
			strike(ctx, unit, foe, now, { Multiplier = multiplier, Wave = wave })
			-- Enfraquecimento do passo (pneu da Boneca: -30% de Velocidade por 2 turnos)
			if step.Debuff and not foe.Ko then
				addDebuff(ctx, unit, foe, step.Debuff, now)
			end
		end
	elseif step and step.Fx == "HeadJump" then
		-- O 1º pulo também espera tocar o alvo (vai para a fila, sem aviso: o aviso do começo já saiu)
		table.insert(
			unit.Queue,
			{ At = now + hitDelay(unit, step, 1), Target = target, Hit = 1, Multiplier = multiplier }
		)
	else
		strike(ctx, unit, target, now, {
			Multiplier = multiplier,
			ForcedCrit = forcedCrit,
			StunTurns = if step then step.StunTurns else nil,
			Push = true,
			Basic = not special,
		})
	end
	-- Os outros golpes do padrão saem em seguida (BrawlSkills.runQueue)
	for hit = 2, hits do
		local final = if step and step.FinalMultiplier and hit == hits then step.FinalMultiplier else 1
		table.insert(unit.Queue, {
			-- No ritmo das animações de verdade (ComboTiming; 07/11/2026: a cada 0,3 s uma cortava a outra)
			At = now + hitDelay(unit, step, hit),
			Target = target,
			Hit = hit,
			Multiplier = baseMultiplier * final,
			Fx = step and step.Fx,
		})
	end
	if step and step.HealPercent then
		heal(ctx, unit, step.HealPercent * unit.MaxHp)
	end
	if not unit.Ko and not target.Ko then
		extraAttacks(ctx, unit, target, false, now)
	end
	stackFury(ctx, unit)

	local interval = BrawlSkills.attackInterval(unit, now) -- antes de gastar o golpe do SpdUp
	if unit.InitiativeHits > 0 then
		unit.InitiativeHits -= 1
	end
	unit.Cooldown = interval + hitDelay(unit, step, hits)
	unit.Hitting = true
end

function BrawlSkills.attack(ctx: any, unit: any, target: any, now: number)
	if shellBlocks(ctx, unit, now) then
		return
	end
	attackTurn(ctx, unit, target, now)
	-- O ataque dele conta para a Casca de Coco
	shellCount(ctx, unit, now)
end

-- Golpe em um alvo de evento (piñata): as habilidades de ataque valem e viram multiplicador em deal(multiplicador).
-- artificial(tipo) (14/11/2026, Patapim): a cada golpe, os itens que dariam dano à parte avisam ("MaxHpHit" da Jakalopita,
-- "FirstStrike" do Julgamento no 1º turno da janela); o alvo decide quanto vale
-- dealHit(multiplicador, básico): básico = o golpe comum, sem padrão de habilidade (gráfico de dano da Piñata, 16/11/2026)
function BrawlSkills.bagAttack(
	ctx: any,
	unit: any,
	now: number,
	dealHit: (number, boolean) -> (),
	artificial: ((string) -> ())?
)
	local function deal(multiplier: number, basic: boolean?)
		dealHit(multiplier, basic == true)
		if not artificial then
			return
		end
		local clock = os.clock()
		if #effects(unit, "MaxHpHit") > 0 then
			artificial("MaxHpHit")
		end
		if #effects(unit, "FirstStrike") > 0 then
			unit.FirstStrikeAt = unit.FirstStrikeAt or clock
			if clock - unit.FirstStrikeAt <= SKILLS.TurnSeconds then
				artificial("FirstStrike")
			end
		end
	end
	local function extras(before: boolean)
		for _, effect in effects(unit, "ExtraAttack") do
			local count = 0
			while
				(effect.Before == true) == before
				and count < (effect.Chain or 1)
				and extraFires(ctx, unit, effect, before, count)
			do
				count += 1
				ctx.emit(unit, unit.PassiveName, effect.Fx)
				deal(effect.Multiplier or 1)
			end
		end
	end
	extras(true)
	unit.Attacks += 1
	countHit(ctx, unit, true)
	-- Turno de habilidade (15/11/2026): Za Warudo e onda de Every no lugar do golpe
	if zaWarudo(ctx, unit, nil, deal) or everyExtra(ctx, unit, nil, now, deal) then
		stackFury(ctx, unit)
		unit.Cooldown = BrawlSkills.attackInterval(unit, now) + hitDelay(unit, nil, 1)
		unit.Hitting = true
		return
	end

	local step = patternStep(unit)
	local hits = if step and step.Hits then step.Hits else 1
	-- Um sorteio só, chances somadas (20/11/2026, igual ao BattleEngine)
	local critChance, critMultiplier, critNamed = BrawlConfig.CritChance, BrawlConfig.CritMultiplier, false
	for _, effect in effects(unit, "Crit") do
		critChance += effect.Chance or 0
		critMultiplier = math.max(critMultiplier, effect.Multiplier or BrawlConfig.CritMultiplier)
		critNamed = critNamed or (effect.Chance or 0) > 0
	end
	local crit = 1
	if critChance >= 1 or roll(ctx, critChance) then
		crit = critMultiplier
		if critNamed then
			ctx.emit(unit, unit.PassiveName)
		end
	end
	local base = (1 + unit.PendingBonus) * (unit.Charged or 1) * (1 + unit.Fury) * debuffFactor(unit, "Atk", now)
	unit.PendingBonus = 0
	unit.Charged = nil
	if step then
		if step.Crit then
			crit = math.max(crit, step.Multiplier or BrawlConfig.CritMultiplier)
		else
			base *= step.Multiplier or 1
		end
		if next(step) ~= nil then
			ctx.emit(unit, unit.PassiveName, step.Fx, if step.Fx then 1 else nil, ctx.bagGround())
		end
		if step.HealPercent then
			heal(ctx, unit, step.HealPercent * unit.MaxHp)
		end
	end
	local multiplier = base * crit
	local firstHit = multiplier * (if step and step.FinalMultiplier and hits == 1 then step.FinalMultiplier else 1)
	if step and step.Fx == "HeadJump" then
		task.delay(hitDelay(unit, step, 1), function()
			if not unit.Ko then
				deal(firstHit)
			end
		end)
	else
		deal(firstHit, step == nil or next(step) == nil)
	end
	for hit = 2, hits do
		local final = if step and step.FinalMultiplier and hit == hits then step.FinalMultiplier else 1
		task.delay(hitDelay(unit, step, hit), function()
			if not unit.Ko then
				ctx.emit(unit, unit.PassiveName, step and step.Fx, hit, ctx.bagGround())
				deal(base * final)
			end
		end)
	end
	extras(false)
	stackFury(ctx, unit)
	unit.Cooldown = BrawlSkills.attackInterval(unit, now) + hitDelay(unit, step, hits)
	unit.Hitting = true
end

-- Golpes que faltam da sequência. Retorna true se ainda está no meio dela (não anda enquanto isso).
function BrawlSkills.runQueue(ctx: any, unit: any, now: number): boolean
	local queued = unit.Queue[1]
	if not queued then
		return false
	end
	if queued.Target.Ko then
		unit.Queue = {} -- o alvo caiu: as pancadas que faltavam não vão para outro
		return false
	end
	if now >= queued.At then
		table.remove(unit.Queue, 1)
		if queued.Fx then
			ctx.emit(unit, unit.PassiveName, queued.Fx, queued.Hit, queued.Target.Position)
		end
		strike(ctx, unit, queued.Target, now, { Multiplier = queued.Multiplier, Push = true })
		unit.Hitting = true
	end
	return true
end

-- Habilidades "de início da luta" (escudo, escudo do time, Arrancada, golpe de abertura). Na briga não há começo: elas
-- valem ao chegar ao Coliseu e de novo a cada SKILLS.RestartSeconds (13/11/2026, pedido do usuário). O escudo não
-- acumula: volta a ser pelo menos o valor da habilidade
-- Hora (os.clock) em que as habilidades de início de cada brainrot dispararam por último: dono → id → hora.
-- Fica fora da unidade porque tirar e pôr de novo no time cria outra (18/11/2026, pedido do usuário: era um
-- "cheese" para soltar o escudo/NUKE de novo antes dos 10 s)
local lastStart: { [any]: { [string]: number } } = setmetatable({}, { __mode = "k" }) :: any

local function startSkills(ctx: any, unit: any, allies: { any })
	local byId = lastStart[unit.Owner] or {}
	lastStart[unit.Owner] = byId
	byId[unit.BrainrotId] = os.clock()
	-- O "1º turno" do Julgamento de Eyros recomeça junto (14/11/2026, pedido do usuário): no próximo golpe abre outra janela
	unit.FirstStrikeAt = nil
	for _, effect in effects(unit, "Shield") do
		unit.Shield = math.max(unit.Shield, (effect.Percent or 0) * unit.MaxHp)
		ctx.emit(unit, unit.PassiveName)
	end
	local initiative = effects(unit, "Initiative")[1]
	if initiative then
		unit.InitiativeHits = initiative.Turns or 1
		unit.Cooldown = 0
		ctx.emit(unit, unit.PassiveName)
	end
	for _, effect in effects(unit, "TeamShield") do
		for _, ally in allies do
			if not ally.Ko then
				local amount = (effect.Percent or 0) * (if effect.OwnMaxHp then ally.MaxHp else unit.MaxHp)
				ally.Shield = math.max(ally.Shield, amount)
			end
		end
		ctx.emit(unit, unit.PassiveName, "Shield")
	end
	-- Golpe de abertura (NUKE do Bombardiro): só com alvo de evento (Patapim, piñata); sem evento não tem em quem
	-- (13/11/2026: soltava a NUKE no chão sozinho com o Coliseu vazio)
	if ctx.bagGround() then
		for _, effect in effects(unit, "OpeningStrike") do
			ctx.emit(unit, unit.PassiveName, effect.Fx, nil, ctx.bagGround())
			ctx.hitBag(unit, effect.Multiplier or 1)
		end
		-- Napalm do Bombombini (15/11/2026): na briga o único alvo é o de evento
		for _, effect in effects(unit, "OpeningSnipe") do
			ctx.emit(unit, unit.PassiveName, effect.Fx, nil, ctx.bagGround())
			ctx.hitBag(unit, effect.Multiplier or 1)
		end
	end
end

-- Queimadura e cura por turno, no ritmo de TurnSeconds; habilidades de início a cada RestartSeconds
function BrawlSkills.tick(ctx: any, unit: any, dt: number, now: number)
	if unit.Ko then
		return
	end
	-- Só durante um evento com alvo (Patapim, piñata): parado no Coliseu sem evento, nada se repete (13/11/2026)
	if ctx.bagGround() then
		unit.RestartTimer = (unit.RestartTimer or 0) + dt
		if unit.RestartTimer >= SKILLS.RestartSeconds then
			unit.RestartTimer -= SKILLS.RestartSeconds
			startSkills(ctx, unit, ctx.allies(unit))
		end
	else
		unit.RestartTimer = 0
	end
	if unit.BurnUntil > now then
		unit.BurnTimer += dt
		if unit.BurnTimer >= SKILLS.TurnSeconds then
			unit.BurnTimer -= SKILLS.TurnSeconds
			damage(ctx, unit.BurnSource, unit, unit.BurnPercent * unit.MaxHp)
		end
	end
	local healing = effects(unit, "HealPerTurn")
	if #healing > 0 and not unit.Ko then
		unit.HealTimer += dt
		if unit.HealTimer >= SKILLS.TurnSeconds then
			unit.HealTimer -= SKILLS.TurnSeconds
			for _, effect in healing do
				heal(ctx, unit, (effect.Percent or 0) * unit.MaxHp)
			end
		end
	end
	-- A cada turno: cura o aliado com a menor fração de Vida, nunca ele mesmo (Giraffa Celeste, 17/11/2026)
	local allyHealing = effects(unit, "TurnHealAlly")
	if #allyHealing > 0 and not unit.Ko then
		unit.AllyHealTimer = (unit.AllyHealTimer or 0) + dt
		if unit.AllyHealTimer >= SKILLS.TurnSeconds then
			unit.AllyHealTimer -= SKILLS.TurnSeconds
			local worst = nil
			for _, ally in ctx.allies(unit) do
				if
					ally ~= unit
					and not ally.Ko
					and ally.Hp < ally.MaxHp
					and (not worst or ally.Hp / ally.MaxHp < worst.Hp / worst.MaxHp)
				then
					worst = ally
				end
			end
			if worst then
				for _, effect in allyHealing do
					heal(ctx, worst, (effect.Percent or 0) * unit.MaxHp)
				end
				ctx.emit(unit, unit.PassiveName, "Heal")
			end
		end
	end
end

-- Chegou ao Coliseu (ou entrou no time lá dentro): as habilidades de início, mas só se já passaram RestartSeconds
-- desde a última vez desse brainrot; senão o relógio continua de onde estava (tirar e pôr não recomeça nada)
function BrawlSkills.onArrive(ctx: any, list: { any })
	local now = os.clock()
	for _, unit in list do
		if not unit.Ko then
			local byId = lastStart[unit.Owner]
			local last = byId and byId[unit.BrainrotId]
			if last and now - last < SKILLS.RestartSeconds then
				unit.RestartTimer = now - last
			else
				unit.RestartTimer = 0
				startSkills(ctx, unit, list)
			end
		end
	end
end

-- Saiu do servidor: esquece as horas dele
function BrawlSkills.forget(owner: any)
	lastStart[owner] = nil
end

return BrawlSkills
]=]
SOURCES["src/shared/Brainrot/BattleDamage.luau"] = [=[
--[[
	BattleDamage — quanto dano cada lutador causou, recebeu e quanta Vida curou numa luta, contado pelo roteiro do
	BattleEngine (14/11/2026, pedido do usuário: tabela no fim de uma dificuldade da Torre, com as abas Dano causado,
	Dano recebido e Vida curada).

		BattleDamage.tally(roteiro) → { Dealt, Taken, Healed }, cada um { [chave do lutador ("A1", "B2"...)]: número }

	Dano: golpe, contra-ataque, revide e habilidades (Dmg), o extra da Jakalopita (MaxHpHit) e do Julgamento de Eyros
	(FirstStrike), espinhos (Reflect), escudo que explode (ShieldBreak) e queimadura (Burn: vai para quem queimou, By).
	Só conta dano entre lados diferentes (o lado é a letra da chave). O escudo que segurou o golpe conta como dano
	recebido (o golpe bateu nele).
	Cura: a Vida que voltou de verdade (Heal.Amount, já sem passar da Vida máxima), para quem curou: Source (cura em
	aliado) ou o próprio (roubo de vida, regeneração, artefato).

	De onde veio o dano causado (14/11/2026, pedido do usuário: barra em pedaços na tabela): DealtBy[chave][fonte],
	fontes em BattleDamage.Sources. Golpe principal = ataque básico; golpe a mais do padrão, contra-ataque, golpe em
	área/extra, queimadura e escudo que explode = habilidade; Jakalopita, Julgamento e Chamas de Goes = itens; espinhos =
	stats. Chamas de Goes (15/11/2026, pedido do usuário) = o dano a mais da penetração (Pierced no evento: o que a
	redução tiraria e o que passou do escudo), tirado de dentro do golpe. No golpe que passa da Vida do alvo, o que
	sobra é cortado do fim: primeiro do Julgamento, depois da Jakalopita, das Chamas, por último do golpe.
]]

local BattleDamage = {}

-- Fontes do dano causado, na ordem da barra. Kind = o grupo que aparece no balão
BattleDamage.Sources = {
	{ Id = "Basic", Label = "Ataque básico", Kind = "Ataque" },
	{ Id = "Skill", Label = "Habilidade", Kind = "Habilidade" },
	-- Dano verdadeiro (17/11/2026, pedido do usuário; True no evento): pedaço próprio, fora de "Habilidade"
	{ Id = "True", Label = "Dano verdadeiro", Kind = "Ignora redução e escudo" },
	{ Id = "Goes", Label = "Chamas de Goes", Kind = "Item" }, -- dano a mais da penetração de escudo e de redução
	{ Id = "Jakalopita", Label = "Jakalopita", Kind = "Item" },
	{ Id = "Judgment", Label = "Julgamento de Eyros", Kind = "Item" },
	{ Id = "Thorns", Label = "Espinhos", Kind = "Stats" },
}

-- Tipo do evento → fonte do dano principal dele
local SOURCE_OF_KIND: { [string]: string } = {
	Attack = "Basic",
	Blow = "Skill",
	Extra = "Skill",
	Counter = "Skill",
	Burn = "Skill",
	ShieldBreak = "Skill",
	DeathBlast = "Skill", -- explosão ao cair (Bombombini; 15/11/2026)
	Reflect = "Thorns",
}

export type Tally = {
	Dealt: { [string]: number },
	Taken: { [string]: number },
	Healed: { [string]: number },
	DealtBy: { [string]: { [string]: number } },
}

-- Lado de um lutador: o Side do Units do roteiro (a Arena de 4 times também tem) ou a letra da chave
local function sideOf(script: any, key: string): string
	local unit = typeof(script.Units) == "table" and script.Units[key]
	return if unit and typeof(unit.Side) == "string" then unit.Side else string.sub(key, 1, 1)
end

local function add(list: { [string]: number }, key: string, amount: number)
	list[key] = (list[key] or 0) + amount
end

function BattleDamage.tally(script: any): Tally
	local result: Tally = { Dealt = {}, Taken = {}, Healed = {}, DealtBy = {} }
	if typeof(script) ~= "table" or typeof(script.Events) ~= "table" then
		return result
	end
	-- Vida e escudo de cada um ao longo da luta (começa pelo Units do roteiro; cada evento traz o depois). O dano
	-- recebido E o causado param no que o alvo tinha (Vida + escudo): o golpe final não conta o que passou da Vida
	-- (14/11/2026, pedido do usuário).
	local hp: { [string]: number } = {}
	local shield: { [string]: number } = {}
	if typeof(script.Units) == "table" then
		for key, unit in script.Units do
			hp[key] = tonumber(unit.Hp) or tonumber(unit.MaxHp)
			shield[key] = 0
		end
	end
	local function after(key: any, event: any)
		if typeof(key) ~= "string" then
			return
		end
		if tonumber(event.Hp) then
			hp[key] = event.Hp
		end
		if tonumber(event.Shield) then
			shield[key] = event.Shield
		end
	end
	for _, event in script.Events do
		if event.T == "Heal" then
			local healer = event.Source or event.U
			local amount = tonumber(event.Amount)
			if typeof(healer) == "string" and amount and amount > 0 then
				add(result.Healed, healer, amount)
			end
			after(event.U, event)
			continue
		elseif event.T == "Shield" then
			if typeof(event.U) == "string" and tonumber(event.Amount) then
				shield[event.U] = event.Amount
			end
			continue
		elseif event.T == "Revive" or event.T == "LevelUp" then
			-- LevelUp (Aura na hora, 15/11/2026): a Vida sobe junto com a Vida máxima, não é cura
			after(event.U, event)
			continue
		end
		local amount = tonumber(event.Dmg)
		if amount and amount > 0 then
			local by, target
			-- Pedaços do dano, na ordem em que o motor tira a Vida: { fonte, quanto }
			local parts = { { if event.True then "True" else SOURCE_OF_KIND[event.T] or "Skill", amount } }
			if event.T == "Burn" then
				by, target = event.By, event.U
			else
				by, target = event.U, event.Target
				local maxHpHit, firstStrike = tonumber(event.MaxHpHit) or 0, tonumber(event.FirstStrike) or 0
				amount += maxHpHit + firstStrike
				-- Chamas de Goes (Pierced): sai do golpe; o que sobrar, da Jakalopita e depois do Julgamento
				local pierced = math.min(tonumber(event.Pierced) or 0, amount)
				local fromMain = math.min(pierced, parts[1][2])
				local fromMaxHp = math.min(pierced - fromMain, maxHpHit)
				parts[1][2] -= fromMain
				table.insert(parts, { "Goes", pierced })
				table.insert(parts, { "Jakalopita", maxHpHit - fromMaxHp })
				table.insert(parts, { "Judgment", firstStrike - (pierced - fromMain - fromMaxHp) })
			end
			local taken = amount
			if typeof(target) == "string" and hp[target] then
				taken = math.min(amount, math.max(0, hp[target] + (shield[target] or 0)))
			end
			if
				typeof(by) == "string"
				and typeof(target) == "string"
				and sideOf(script, by) ~= sideOf(script, target)
			then
				add(result.Dealt, by, taken)
				add(result.Taken, target, taken)
				local sources = result.DealtBy[by] or {}
				result.DealtBy[by] = sources
				local left = taken
				for _, part in parts do
					local counted = math.min(part[2], left)
					if counted > 0 then
						add(sources, part[1], counted)
						left -= counted
					end
				end
			elseif event.T == "Burn" and typeof(target) == "string" and by == nil then
				-- Queimadura de roteiro antigo (sem By): ainda conta como dano recebido
				add(result.Taken, target, taken)
			end
		end
		-- Depois do golpe: a Vida e o escudo de quem levou (na queimadura, U)
		after(if event.T == "Burn" then event.U else event.Target, event)
	end
	return result
end

-- Fontes de um lutador com os números inteiros (só as que têm dano), para mandar à tela
function BattleDamage.rounded(sources: { [string]: number }?): { [string]: number }
	local result = {}
	for id, amount in sources or {} do
		local whole = math.floor(amount + 0.5)
		if whole > 0 then
			result[id] = whole
		end
	end
	return result
end

-- Linhas da tabela (Client/UI/DamageReport) de um lado de UMA luta: um por brainrot desse lado no roteiro (Units),
-- na ordem da fila, com Species/Stars/Level e os três números. PvP e Arena (evento) usam direto no cliente.
function BattleDamage.report(script: any, side: string): { any }
	local tally = BattleDamage.tally(script)
	local keys = {}
	if typeof(script) == "table" and typeof(script.Units) == "table" then
		for key in script.Units do
			if sideOf(script, key) == side then
				table.insert(keys, key)
			end
		end
	end
	table.sort(keys)
	local list = {}
	for _, key in keys do
		local unit = script.Units[key]
		table.insert(list, {
			Species = unit.Species,
			Stars = unit.Stars or 0,
			Mutation = unit.Mutation, -- Dourado (19/11/2026)
			Level = unit.Level or 1,
			Damage = math.floor((tally.Dealt[key] or 0) + 0.5),
			DamageSources = BattleDamage.rounded(tally.DealtBy[key]),
			Taken = math.floor((tally.Taken[key] or 0) + 0.5),
			Healed = math.floor((tally.Healed[key] or 0) + 0.5),
		})
	end
	return list
end

return BattleDamage
]=]
SOURCES["src/shared/Brainrot/BlockModel.luau"] = [=[
-- Gerado por tools/battlesim/build_site: só a duração das animações (o site não leva os modelos 3D)
local LENGTHS = {
	["ChimpanziniBananini"] = { ["attack"] = 0.25, ["crouch_walk"] = 0.59999999999999998, ["idle"] = 6, ["mid_air"] = 10, ["power"] = 1.1000000000000001, ["power_in"] = 1.1000000000000001, ["run"] = 0.94999999999999996, ["run_one"] = 0.5, ["run_two"] = 0.45000000000000001, ["walk"] = 1.1499999999999999, ["walk_one"] = 0.65000000000000002, ["walk_two"] = 0.45000000000000001 },
	["BonecaAmbalabu"] = { ["POSE"] = 0, ["POSE2"] = 0, ["crouch"] = 0, ["idle"] = 10, ["interact"] = 0.34999999999999998, ["power_idle"] = 0, ["power_in"] = 0.45000000000000001, ["power_walk"] = 0, ["run"] = 1.7, ["run_2"] = 1.7, ["walk"] = 0.55000000000000004 },
	["GlorboFruttodrillo"] = { ["attack"] = 0.55000000000000004, ["attack_grab"] = 0, ["bite"] = 0.55000000000000004, ["crouch"] = 0, ["grab_backwards_walk"] = 1, ["idle"] = 12, ["idle_2"] = 1.8500000000000001, ["interact"] = 0.40000000000000002, ["run"] = 0.69999999999999996, ["walk"] = 1 },
	["FrigoCamelo"] = { ["attack"] = 1.3, ["crouch"] = 0, ["idle"] = 12, ["interact"] = 0.5, ["run"] = 1, ["walk"] = 1 },
	["LiriliLarila"] = { ["attack"] = 0.65000000000000002, ["clock_idle"] = 0, ["idle"] = 7, ["run"] = 0.55000000000000004, ["walk"] = 0.55000000000000004, ["za_warudo"] = 1.25 },
	["TungTungTungSahur"] = { ["attack"] = 0.55000000000000004, ["attack2"] = 0.80000000000000004, ["attack3"] = 1, ["aura"] = 2, ["crouch"] = 0, ["idle"] = 8, ["idle_2"] = 2, ["interact"] = 0.55000000000000004, ["laugh"] = 1, ["pose"] = 0, ["run"] = 0.65000000000000002, ["walk"] = 1 },
	["TrulimeroTrulichina"] = { ["attack"] = 0.71999999999999997, ["idle"] = 4, ["run"] = 0.46000000000000002, ["walk"] = 0.80000000000000004 },
	["BallerinaCappuccina"] = { ["crouch"] = 0, ["crouch_walk"] = 1.5, ["idle"] = 4, ["idle_2"] = 2, ["interact"] = 0.5, ["parry"] = 0.64439999999999997, ["power"] = 1.05, ["run"] = 1, ["walk"] = 1 },
	["OdinDinDinDun"] = { ["attack"] = 0.68000000000000005, ["flex"] = 2, ["idle"] = 4, ["run"] = 0.5, ["walk"] = 0.81999999999999995 },
	["TralaleroTralala"] = { ["attack"] = 0.71999999999999997, ["dance"] = 1.2, ["idle"] = 4, ["run"] = 0.47999999999999998, ["surf"] = 1.5, ["walk"] = 0.80000000000000004 },
	["GiraffaCeleste"] = { ["attack"] = 0.80000000000000004, ["idle"] = 4, ["run"] = 0.55000000000000004, ["walk"] = 0.94999999999999996 },
	["BurbaloniLuliloli"] = { ["attack"] = 0.69999999999999996, ["idle"] = 4, ["interact"] = 0.45000000000000001, ["power"] = 1, ["power_idle"] = 0, ["test"] = 0.69999999999999996, ["walk"] = 1 },
	["TrippiTroppi"] = { ["attack"] = 0.71999999999999997, ["confused"] = 2.3999999999999999, ["idle"] = 4, ["run"] = 0.41999999999999998, ["walk"] = 0.69999999999999996 },
	["BombombiniGusini"] = { ["attack"] = 0.80000000000000004, ["idle"] = 4, ["run"] = 0.69999999999999996, ["walk"] = 1.1000000000000001 },
	["BrrBrrPatapim"] = { ["attack"] = 0.84999999999999998, ["idle"] = 2.3999999999999999, ["run"] = 0.54000000000000004, ["slam"] = 1.8, ["summon"] = 2.5, ["tap"] = 1.8, ["walk"] = 0.88 },
	["CappuccinoAssassino"] = { ["attack"] = 0.90000000000000002, ["idle"] = 1.7, ["parry"] = 0.84999999999999998, ["run"] = 0.40000000000000002, ["walk"] = 0.80000000000000004 },
	["LaVacaSaturnoSaturnita"] = { ["attack"] = 0.84999999999999998, ["idle"] = 4, ["orbit"] = 2.6000000000000001, ["run"] = 0.52000000000000002, ["walk"] = 0.88 },
	["BobritoBandito"] = { ["attack"] = 0.68000000000000005, ["guard"] = 2.7999999999999998, ["idle"] = 4, ["run"] = 0.45000000000000001, ["walk"] = 0.75 },
	["BombardiroCrocodilo"] = { ["crouch"] = 0, ["idle"] = 6, ["interact"] = 0.59999999999999998, ["power"] = 3, ["run"] = 4, ["walk"] = 2 },
	["BlueberriniOctopussini"] = { ["attack"] = 0.5, ["idle"] = 0, ["run"] = 0.69999999999999996, ["spell"] = 0.59999999999999998, ["walk"] = 1.5 },
}
local BlockModel = {}
function BlockModel.exists(id)
	return LENGTHS[id] ~= nil
end
function BlockModel.rig(id)
	local animations = {}
	for name, length in LENGTHS[id] or {} do
		animations[name] = { length = length }
	end
	return { animations = animations }
end
return BlockModel]=]
SOURCES["src/shared/Brainrot/BrainrotStats.luau"] = [=[
--[[
	BrainrotStats — contas de um brainrot (iguais no servidor e no cliente).

		BrainrotStats.get(brainrot)        → { Hp, Atk, Spd } finais
		BrainrotStats.breakdown(brainrot)  → de onde vem cada stat: { Hp = { Base, Talent, Bonus, Total }, ... }
		BrainrotStats.power(brainrot)      → Poder (número único que resume a força)
		BrainrotStats.powerOf(stats)       → Poder de stats já prontos (ex.: chefe da Torre)
		BrainrotStats.bestOrder(list)      → a mesma lista na melhor ordem de fila para lutar
		BrainrotStats.perfection(talentMax) → 0 a 1 (média dos tetos ÷ 100; 1 = todos no máximo)
		BrainrotStats.xpToNext(level)      → Aura para passar do nível `level` para o próximo
		BrainrotStats.xpCurve(level)       → a mesma conta sem o teto do nível máximo (Aura dos inimigos da Torre)
		BrainrotStats.income(brainrot)     → moedas por segundo exposto no terreno
		BrainrotStats.sellValue(brainrot)  → moedas ao vender
		BrainrotStats.displayName(brainrot)

	Base do stat = Base da espécie × (1 + bônus das estrelas)   (a raridade já está na Base)
	Stat = Base × (1 + nível% + talento atual / 100), com nível% = BrainrotConfig.LevelStatBonus × (nível − 1)
	(05/11/2026: cada nível dá +2% da base; ex.: base 300, nível 28 (+54%) e talento 40 → 300 + 162 + 120 = 582)
	Em cima disso, o artefato soma a sua % desse total; o tamanho (12/11/2026; Config/SizeConfig: até +200%) soma a sua % da Base.
]]

local Config = script.Parent.Parent.Config
local ArtifactConfig = require(Config.ArtifactConfig)
local BrainrotConfig = require(Config.BrainrotConfig)
local RarityConfig = require(Config.RarityConfig)
local SizeConfig = require(Config.SizeConfig)
local MutationConfig = require(Config.MutationConfig)
local SpeciesConfig = require(Config.SpeciesConfig)
local Types = require(script.Parent.Parent.Types)

export type Stats = { Hp: number, Atk: number, Spd: number }
export type StatPart = {
	Base: number, -- o stat da espécie com as estrelas (sem nível e sem talento)
	Level: number, -- % que o nível soma (0.54 = +54%)
	LevelBonus: number, -- quanto o nível soma (Base × Level)
	Talent: number, -- talento atual, em %
	Bonus: number, -- quanto o talento soma (Base × Talent / 100)
	Artifact: number, -- % que o artefato soma no total (0.2 = +20%)
	ArtifactBonus: number, -- quanto o artefato soma
	Size: number, -- % que o tamanho soma no total (0.75 = +75%; Config/SizeConfig)
	SizeBonus: number, -- quanto o tamanho soma
	Mutation: number, -- % que a mutação soma (0.25 = +25%; Config/MutationConfig, Dourado)
	MutationBonus: number, -- quanto a mutação soma
	Total: number,
}
export type Breakdown = { Hp: StatPart, Atk: StatPart, Spd: StatPart }

local STAT_KEYS = { "Hp", "Atk", "Spd" }

local BrainrotStats = {}

BrainrotStats.Keys = STAT_KEYS

local function starBonus(stars: number): number
	return if stars > 0 then BrainrotConfig.StarBonus[math.min(stars, #BrainrotConfig.StarBonus)] else 0
end

local function talentOf(brainrot: Types.BrainrotData, key: string): number
	local talents = brainrot.Talents :: any
	return math.clamp(tonumber(talents and talents[key]) or 0, 0, BrainrotConfig.MaxTalent)
end

function BrainrotStats.breakdown(brainrot: Types.BrainrotData): Breakdown
	local species = SpeciesConfig.get(brainrot.Species)
	local result = {}
	for _, key in STAT_KEYS do
		local base = 0
		if species then
			base = math.floor((species.Base :: any)[key] * (1 + starBonus(brainrot.Stars)) + 0.5)
		end
		local levelShare = BrainrotConfig.LevelStatBonus * (math.max(1, brainrot.Level) - 1)
		local levelBonus = math.floor(base * levelShare + 0.5)
		local talent = talentOf(brainrot, key)
		local bonus = math.floor(base * talent / 100 + 0.5)
		local subtotal = base + levelBonus + bonus
		-- Tamanho: até +200% da BASE (12/11/2026, pedido do usuário: base 1000 com +200% = +2000)
		local size = SizeConfig.statShare((brainrot :: any).Size)
		local sizeBonus = math.floor(base * size + 0.5)
		-- Artefato: +% em cima de TUDO (17/11/2026, pedido do usuário; antes só base + nível + talento). As skills da
		-- árvore multiplicam o total depois (BattleService), e como é multiplicação o artefato vale sobre elas também
		-- Mutação (Dourado +25%, 19/11/2026, pedido do usuário): em cima de base + nível + talento + tamanho; o
		-- artefato vem depois e conta em cima dela
		local mutation = MutationConfig.statBonus(brainrot)
		local mutationBonus = math.floor((subtotal + sizeBonus) * mutation + 0.5)
		local artifact = ArtifactConfig.statBonusOf(brainrot, key)
		local artifactBonus = math.floor((subtotal + sizeBonus + mutationBonus) * artifact + 0.5)
		result[key] = {
			Base = base,
			Level = levelShare,
			LevelBonus = levelBonus,
			Talent = talent,
			Bonus = bonus,
			Artifact = artifact,
			ArtifactBonus = artifactBonus,
			Size = size,
			SizeBonus = sizeBonus,
			Mutation = mutation,
			MutationBonus = mutationBonus,
			Total = subtotal + artifactBonus + sizeBonus + mutationBonus,
		}
	end
	return result :: Breakdown
end

function BrainrotStats.get(brainrot: Types.BrainrotData): Stats
	local parts = BrainrotStats.breakdown(brainrot)
	return { Hp = parts.Hp.Total, Atk = parts.Atk.Total, Spd = parts.Spd.Total }
end

-- Poder = √(Vida × Ataque × Velocidade): na luta, o dano por segundo é ∝ Ataque × Velocidade e o
-- tempo que ele aguenta é ∝ Vida. Acerta quem vence em ~91% das lutas (a soma com pesos acertava 78%).
function BrainrotStats.powerOf(stats: Stats): number
	return math.floor(math.sqrt(math.max(0, stats.Hp * stats.Atk * stats.Spd)) + 0.5)
end

function BrainrotStats.power(brainrot: Types.BrainrotData): number
	return BrainrotStats.powerOf(BrainrotStats.get(brainrot))
end

-- Todas as ordens possíveis de uma lista pequena (até 3 itens = 6 ordens)
local function permutations<T>(list: { T }): { { T } }
	if #list <= 1 then
		return { table.clone(list) }
	end
	local result = {}
	for index, item in list do
		local rest = table.clone(list)
		table.remove(rest, index)
		for _, tail in permutations(rest) do
			table.insert(tail, 1, item)
			table.insert(result, tail)
		end
	end
	return result
end

-- Melhor ordem da fila (posição 1 = frente, que apanha primeiro): a de maior
-- F = soma de (Ataque × Velocidade) × (Vida dele + de quem está na frente). Na prática: Tanque na frente.
function BrainrotStats.bestOrder(list: { Types.BrainrotData }): { Types.BrainrotData }
	local best, bestScore = list, -1
	for _, order in permutations(list) do
		local score, shield = 0, 0
		for _, brainrot in order do
			local stats = BrainrotStats.get(brainrot)
			shield += stats.Hp
			score += stats.Atk * stats.Spd * shield
		end
		if score > bestScore then
			best, bestScore = order, score
		end
	end
	return best
end

-- Média dos TETOS de talento sobre o máximo possível (06/11/2026, pedido do usuário): 50/50/50 = 50%, 100/100/100 =
-- 100%. Antes contava a partir do mínimo sorteável (20), e 50/50/50 aparecia como 38%.
function BrainrotStats.perfection(talentMax: Types.Talents?): number
	if not talentMax then
		return 0
	end
	local high = BrainrotConfig.TalentMaxMax
	local sum = (talentMax.Hp or 0) + (talentMax.Atk or 0) + (talentMax.Spd or 0)
	return math.clamp(sum / (3 * high), 0, 1)
end

-- A curva de XP sem o teto: quanto custaria passar do nível `level` para o próximo, mesmo no máximo (13/11/2026: a
-- Aura dos inimigos da Torre conta "do 200 para o 201", que não existe)
function BrainrotStats.xpCurve(level: number): number
	return math.floor(
		BrainrotConfig.XpBase + BrainrotConfig.XpScale * (math.max(1, level) - 1) ^ BrainrotConfig.XpExponent
	)
end

-- Aura (XP) para passar do nível `level` para o próximo (math.huge no nível máximo)
function BrainrotStats.xpToNext(level: number): number
	if level >= BrainrotConfig.MaxLevel then
		return math.huge
	end
	return BrainrotStats.xpCurve(level)
end

function BrainrotStats.income(brainrot: Types.BrainrotData): number
	local species = SpeciesConfig.get(brainrot.Species)
	if not species then
		return 0
	end
	return RarityConfig.get(species.Rarity).Income * (1 + BrainrotConfig.IncomePerLevel * (brainrot.Level - 1))
end

function BrainrotStats.sellValue(brainrot: Types.BrainrotData): number
	local species = SpeciesConfig.get(brainrot.Species)
	if not species then
		return 0
	end
	return math.floor(
		RarityConfig.get(species.Rarity).SellValue * (1 + BrainrotConfig.SellPerLevel * (brainrot.Level - 1))
	)
end

function BrainrotStats.displayName(brainrot: Types.BrainrotData): string
	local species = SpeciesConfig.get(brainrot.Species)
	return if species then species.Name else brainrot.Species
end

return BrainrotStats
]=]
SOURCES["src/shared/Brainrot/ComboTiming.luau"] = [=[
--[[
	ComboTiming — quando sai cada pancada de uma sequência (as 3 do Tung), pelas animações de verdade do modelo
	(07/11/2026: na briga as 3 saíam a cada 0,3 s e uma animação cortava a outra).

		ComboTiming.offset(speciesId, hit) → segundos depois da 1ª pancada em que a pancada `hit` acerta
		ComboTiming.starts(speciesId, hits) → { [hit] = segundos depois do começo da 1ª animação em que cada uma começa }

	As animações tocam uma atrás da outra (Config/BlockAnimConfig: Attacks[n] = { Name, Hit }): a pancada n acerta no
	começo da animação n + Hit dela. Sem animação de golpe, cai no ritmo fixo (BrawlConfig.Skills.ComboGap).
]]

local Shared = script.Parent.Parent
local BlockAnimConfig = require(Shared.Config.BlockAnimConfig)
local BrawlConfig = require(Shared.Config.BrawlConfig)
local BlockModel = require(script.Parent.BlockModel)

local ComboTiming = {}

local function length(speciesId: string, name: string): number?
	if not BlockModel.exists(speciesId) then
		return nil
	end
	local animation = BlockModel.rig(speciesId).animations[name]
	return animation and animation.length
end

-- Começo de cada animação da sequência (a 1ª em 0)
function ComboTiming.starts(speciesId: string, hits: number): { number }?
	local config = BlockAnimConfig.get(speciesId)
	local attacks = config and config.Attacks
	if not attacks or #attacks < hits then
		return nil
	end
	local result = { 0 }
	for hit = 2, hits do
		local previous = length(speciesId, attacks[hit - 1].Name)
		if not previous then
			return nil
		end
		result[hit] = result[hit - 1] + previous
	end
	return result
end

function ComboTiming.offset(speciesId: string, hit: number): number
	if hit <= 1 then
		return 0
	end
	local starts = ComboTiming.starts(speciesId, hit)
	local attacks = (BlockAnimConfig.get(speciesId) or {}).Attacks
	if not starts or not attacks then
		return (hit - 1) * BrawlConfig.Skills.ComboGap
	end
	return starts[hit] + attacks[hit].Hit - attacks[1].Hit
end

return ComboTiming
]=]
SOURCES["src/shared/Brainrot/PassivePower.luau"] = [=[
--[[
	PassivePower — as habilidades crescem com as estrelas (13/11/2026, pedido do usuário): cada estrela deixa a
	habilidade CombatConfig.PassiveStarBonus (50%) mais forte, somando (0★ = 1x, 1★ = 1,5x, 2★ = 2x, 3★ = 2,5x).

		PassivePower.factor(estrelas)                → 1 + 0,5 × estrelas
		PassivePower.effects(espécie, estrelas)      → os Effects da passiva já crescidos (cópia, guardada em cache)
		PassivePower.passive(espécie, estrelas)      → a Passive inteira com esses Effects (para PassiveText.describe)

	O que cresce:
	  - chances (Chance, até PassiveMaxChance) e dano (Multiplier, FinalMultiplier, CounterPercent, BreakDamage,
	    NextAttackBonus, Vulnerable), cura do padrão (HealPercent);
	  - o Percent dos efeitos de defesa e cura: redução de dano (até PassiveMaxReduction), espinhos, roubo de vida,
	    escudos, curas, queimadura e a Vida da Revive. Redução POR CHANCE (Escudo Romano do Bombicus): só a chance cresce.
	Melhoria própria: efeito com StarThresholds troca as marcas de Vida pela lista da estrela (Pot Hotspot: 1★ 33/66%,
	2★ 25/50/75%, 3★ 20/40/60/80%). StarAdd = { Campo = n } soma n por estrela num número (o Cappuccino usou para +1 recarga
	da esquiva por ★ e largou no mesmo dia, 15/11/2026; nenhum usa agora).
	O que NÃO cresce: efeitos como lentidão/enfraquecimento (Percent do Debuff), bônus de Velocidade (SpeedBonus), fúria
	(PerTurn/Max e Fury), turnos, contagens. A MENOS que a habilidade não tenha mais nada que cresça: aí esses crescem
	(La Vaca: lentidão; Odin: fúria; Tracotucotulu: arrancada). Habilidade sem nenhum número que cresça fica igual
	(Ta Ta Ta Sahur).
	Só a passiva da espécie cresce; árvore de skills e artefatos não.
]]

local CombatConfig = require(script.Parent.Parent.Config.CombatConfig)

local PassivePower = {}

-- Crescem em qualquer efeito (chances e dano)
local ALWAYS = {
	Chance = true,
	Multiplier = true,
	FinalMultiplier = true,
	CounterPercent = true,
	BreakDamage = true,
	BreakHpDamage = true, -- 16/11/2026: Shield, fração da Vida máxima
	NextAttackBonus = true,
	Vulnerable = true,
	HealPercent = true,
}

-- Tipos em que o Percent é defesa, cura ou dano (cresce sempre)
local PERCENT_TYPES = {
	DamageReduction = true,
	Reflect = true,
	Lifesteal = true,
	Shield = true,
	TeamShield = true,
	TeamShieldEvery = true,
	HealPerTurn = true,
	TeamHeal = true,
	TurnHealAlly = true, -- cura o aliado mais ferido no começo do turno (Giraffa Celeste, 17/11/2026)
	HealEveryHits = true, -- cura a cada N ataques (Trulimero, 14/11/2026)
	Burn = true,
	Revive = true,
	CocoShell = true, -- redução de dano da Casca de Coco (Burbaloni, 19/11/2026; teto PassiveMaxReduction)
}

-- Só crescem quando a habilidade não tem mais nada que cresça
local FALLBACK = { SpeedBonus = true, PerTurn = true, Max = true }

local cache: { [string]: { any } } = {}
local grew: { [string]: boolean } = {} -- espécie → os +50% mudaram algum número

function PassivePower.factor(stars: number?): number
	return 1 + CombatConfig.PassiveStarBonus * math.max(0, stars or 0)
end

local function grows(kind: string, field: string, fallback: boolean, source: { [any]: any }): boolean
	if ALWAYS[field] then
		return true
	end
	-- Bloqueio por chance (Escudo Romano do Bombicus; pedido do usuário): só a chance cresce, não o quanto bloqueia
	if field == "Percent" and kind == "DamageReduction" and (source.Chance or 1) < 1 then
		return false
	end
	if field == "Percent" then
		return PERCENT_TYPES[kind] == true or (fallback and kind == "Debuff")
	end
	-- Espinhos da Casca de Coco crescem junto
	if field == "Thorns" and kind == "CocoShell" then
		return true
	end
	return fallback and FALLBACK[field] == true
end

local function capped(kind: string, field: string, value: number): number
	if field == "Chance" then
		return math.min(value, CombatConfig.PassiveMaxChance)
	elseif field == "Percent" and (kind == "DamageReduction" or kind == "Debuff" or kind == "CocoShell") then
		return math.min(value, CombatConfig.PassiveMaxReduction)
	end
	return value
end

-- Cópia funda de um efeito (ou passo do padrão) com os números crescidos; changed.n conta o que mudou
local function scale(source: { [any]: any }, kind: string, factor: number, fallback: boolean, changed: { n: number })
	local copy = {}
	for key, value in source do
		if typeof(value) == "table" then
			copy[key] = scale(value, if key == "Debuff" then "Debuff" else kind, factor, fallback, changed)
		elseif typeof(value) == "number" and typeof(key) == "string" and grows(kind, key, fallback, source) then
			local grown = capped(kind, key, value * factor)
			-- Nunca diminui (uma chance acima do teto continua como estava)
			grown = math.max(grown, value)
			if grown ~= value then
				changed.n += 1
			end
			copy[key] = grown
		else
			copy[key] = value
		end
	end
	return copy
end

local function scaleAll(effects: { any }, factor: number, fallback: boolean): ({ any }, number)
	local changed = { n = 0 }
	local list = {}
	for index, effect in effects do
		list[index] = scale(effect, effect.Type or "", factor, fallback, changed)
	end
	return list, changed.n
end

-- Effects da passiva da espécie com as estrelas (species = a tabela do SpeciesConfig)
function PassivePower.effects(species: any, stars: number?): { any }
	local count = math.max(0, math.floor(stars or 0))
	local effects = species.Passive.Effects
	if count == 0 then
		return effects
	end
	local key = `{species.Id}:{count}`
	local cached = cache[key]
	if cached then
		return cached
	end
	local factor = PassivePower.factor(count)
	local list, changed = scaleAll(effects, factor, false)
	if changed == 0 then
		list, changed = scaleAll(effects, factor, true)
	end
	grew[species.Id] = changed > 0
	-- Melhoria própria por estrela (StarThresholds do Sem Sinal do Pot Hotspot): troca as marcas de Vida inteiras
	for _, effect in list do
		local byStars = effect.StarThresholds
		if byStars then
			effect.Thresholds = table.clone(byStars[math.min(count, #byStars)] or effect.Thresholds)
		end
		-- Soma por estrela (StarAdd do Golpe Ninja do Cappuccino: +1 recarga da esquiva por ★)
		for field, add in effect.StarAdd or {} do
			if typeof(effect[field]) == "number" then
				effect[field] += add * count
			end
		end
	end
	cache[key] = list
	return list
end

-- Sem Sinal (LowHpRush): a Vida (fração) passou para baixo de alguma marca ainda não usada? Marca em `crossed` (índice
-- da marca → true) todas as que passou de uma vez e retorna true se passou de alguma (um golpe que atravessa duas
-- marcas dá um turno só). rearm = marca que a Vida voltou a superar fica pronta de novo (briga: cura no terreno).
function PassivePower.crossThresholds(
	effect: any,
	crossed: { [number]: boolean },
	share: number,
	rearm: boolean?
): boolean
	local fired = false
	for index, mark in effect.Thresholds or { effect.Threshold or 0.5 } do
		if share < mark then
			if not crossed[index] then
				crossed[index] = true
				fired = true
			end
		elseif rearm then
			crossed[index] = nil
		end
	end
	return fired
end

-- Os números da habilidade crescem os +50% por estrela? (falso: Ta Ta Ta Sahur, que não tem número que cresça, e
-- Pot Hotspot, que tem melhoria própria). A mochila só escreve "+X% pelas estrelas" quando é verdade.
function PassivePower.growsWithStars(species: any): boolean
	if grew[species.Id] == nil then
		PassivePower.effects(species, 1)
	end
	return grew[species.Id] == true
end

-- A passiva inteira (nome, textos, Fx) com os Effects crescidos
function PassivePower.passive(species: any, stars: number?): any
	if math.max(0, math.floor(stars or 0)) == 0 then
		return species.Passive
	end
	local copy = table.clone(species.Passive)
	copy.Effects = PassivePower.effects(species, stars)
	return copy
end

return PassivePower
]=]
SOURCES["src/shared/Brainrot/PassiveText.luau"] = [=[
--[[
	PassiveText — o texto das habilidades sai dos NÚMEROS dos efeitos (pedido do usuário, 06/11/2026): mudar um
	Multiplier/Chance no SpeciesConfig muda o texto sozinho (no futuro as habilidades vão crescer com as estrelas).

		PassiveText.describe(species.Passive) → "15% de chance de uma onda ... com 0.6x o dano."

	Na Description, cada {caminho} vira o valor do efeito:
	  {1.Chance}                    → Effects[1].Chance
	  {1.Pattern.3.FinalMultiplier} → Effects[1].Pattern[3].FinalMultiplier
	  {1.Pattern#}                  → quantos itens tem Effects[1].Pattern
	Formato pelo nome do campo: dano (Multiplier, FinalMultiplier, CounterPercent, BreakDamage) = "1.5x";
	contagens (Turns, Every, Hits...) = número; o resto (Chance, Percent...) = porcentagem ("15%").
	Caminho que não existe fica como está ({...}), para dar para ver o erro.

	Versão da arena (13/11/2026, pedido do usuário): PassiveText.describe(passive, true) usa o ArenaDescription (se não
	tiver, o Description). Nele, {1.Turns:s} = turnos × ArenaBattleConfig.TurnSeconds ("8 s") e {turn} = um turno ("4 s").
]]

local ArenaBattleConfig = require(script.Parent.Parent.Config.ArenaBattleConfig)

local PassiveText = {}

local DAMAGE = { Multiplier = true, FinalMultiplier = true, CounterPercent = true, BreakDamage = true }
local COUNT = {
	Turns = true,
	Every = true,
	Actions = true,
	Uses = true,
	Chain = true,
	Recharges = true,
	Hits = true,
	StunTurns = true,
}

-- Até 2 casas decimais, sem zeros sobrando: 1 → "1", 0.45 → "0.45", 2.50 → "2.5"
local function number(value: number): string
	local text = string.format("%.2f", value)
	text = string.gsub(text, "0+$", "")
	text = string.gsub(text, "%.$", "")
	return text
end

function PassiveText.format(field: string, value: number): string
	if DAMAGE[field] then
		return number(value) .. "x"
	elseif COUNT[field] then
		return number(value)
	end
	return number(value * 100) .. "%"
end

local function resolve(effects: { any }, path: string): string?
	-- Arena: "{caminho:s}" = o número de turnos em segundos
	local seconds = string.sub(path, -2) == ":s"
	if seconds then
		path = string.sub(path, 1, -3)
	end
	local count = string.sub(path, -1) == "#"
	if count then
		path = string.sub(path, 1, -2)
	end
	local node: any = effects
	local last = ""
	for segment in string.gmatch(path, "[^%.]+") do
		if typeof(node) ~= "table" then
			return nil
		end
		local index = tonumber(segment)
		node = if index then node[index] else node[segment]
		last = segment
	end
	if count then
		return if typeof(node) == "table" then tostring(#node) else nil
	end
	if seconds then
		return if typeof(node) == "number" then number(node * ArenaBattleConfig.TurnSeconds) .. " s" else nil
	end
	-- Lista de números (marcas de Vida do Pot Hotspot): "25%, 50% e 75%"
	if typeof(node) == "table" and typeof(node[1]) == "number" then
		local parts = {}
		for _, value in node do
			table.insert(parts, PassiveText.format(last, value))
		end
		if #parts == 1 then
			return parts[1]
		end
		local lastPart = table.remove(parts) :: string
		return table.concat(parts, ", ") .. " e " .. lastPart
	end
	return if typeof(node) == "number" then PassiveText.format(last, node) else nil
end

-- Pedaços do texto (17/11/2026, pedido do usuário; desenhados pelo Client/UI/PassiveLabel): { Text, Damage? }.
-- Damage = o multiplicador do Ataque de um marcador de dano ({1.Multiplier}...), para o balão com o dano em números
-- MaxHp = a fração da Vida máxima DELE (escudo, cura, voltar à vida), para o balão com a conta em números
export type Segment = { Text: string, Damage: number?, MaxHp: number? }

-- Efeitos cujo Percent é da Vida máxima de quem tem a habilidade (BattleEngine)
local OWN_MAX_HP = {
	Shield = true,
	TeamShield = true,
	TeamShieldEvery = true,
	TeamHeal = true,
	TurnHealAlly = true,
	HealPerTurn = true,
	HealEveryHits = true,
	Revive = true,
}

function PassiveText.segments(
	passive: { Description: string, ArenaDescription: string?, Effects: { any } },
	arena: boolean?
): { Segment }
	local source = if arena and passive.ArenaDescription then passive.ArenaDescription else passive.Description
	local list: { Segment } = {}
	local position = 1
	while true do
		local first, last, path = string.find(source, "{([%w%.#:]+)}", position)
		if not first then
			break
		end
		if first > position then
			table.insert(list, { Text = string.sub(source, position, first - 1) })
		end
		local text = if path == "turn"
			then number(ArenaBattleConfig.TurnSeconds) .. " s"
			else resolve(passive.Effects, path)
		local field = string.match(path, "([%a]+)$")
		local node: any = passive.Effects
		local effect: any = nil -- o efeito (Effects[N]) do caminho
		for segment in string.gmatch(path, "[^%.]+") do
			node = if typeof(node) == "table" then node[tonumber(segment) or segment] else nil
			effect = effect or node
		end
		local value = if typeof(node) == "number" then node else nil
		local damage, maxHp = nil, nil
		if field and DAMAGE[field] then
			damage = value
		elseif
			field == "HealPercent"
			or (field == "Percent" and typeof(effect) == "table" and OWN_MAX_HP[effect.Type] and not effect.OwnMaxHp)
		then
			maxHp = value -- % da Vida máxima de quem tem a habilidade
		end
		table.insert(list, { Text = text or string.sub(source, first, last), Damage = damage, MaxHp = maxHp })
		position = last + 1
	end
	if position <= #source then
		table.insert(list, { Text = string.sub(source, position) })
	end
	return list
end

function PassiveText.describe(
	passive: { Description: string, ArenaDescription: string?, Effects: { any } },
	arena: boolean?
): string
	local source = if arena and passive.ArenaDescription then passive.ArenaDescription else passive.Description
	local turn = number(ArenaBattleConfig.TurnSeconds) .. " s"
	local text = string.gsub(source, "{([%w%.#:]+)}", function(path: string)
		if path == "turn" then
			return turn
		end
		return resolve(passive.Effects, path)
	end)
	return text
end

return PassiveText
]=]
SOURCES["src/shared/Config/ArenaBattleConfig.luau"] = [=[
--[[
	ArenaBattleConfig — o evento "Arena" do Coliseu (08/11/2026, pedido do usuário; nota notas/Arena (evento).md).

	4 jogadores, cada um com o time dele (até 3 brainrots), cada um por si:
	  1. DOIS círculos verdes no centro (Rings: Arena 1 e Arena 2; 12/11/2026, pedido do usuário) por LobbyTime (o evento
	     é anunciado 1 min antes, como os outros). Quem estiver dentro quando acabar entra (os MaxPlayers primeiros de cada
	     círculo; quem chegou depois espera vaga). Somando os dois círculos até MaxPlayers jogadores: uma luta só, com
	     todos. Mais que isso: uma luta por círculo, AO MESMO TEMPO (quem entrou junto sempre luta junto; vaga que sobra
	     vira robô). Cada um só vê a própria luta; quem ficou de fora vê a da Arena 1.
	  2. Cada jogador vai para a arquibancada de uma cor, parado em pé, com a câmera fixa atrás dele; os brainrots
	     ficam na frente da arquibancada. Vaga que sobrou vira robô (nível médio dos jogadores; tamanho do
	     time e raridades de um jogador sorteado; avatar padrão do Roblox). PrepTime para arrumar a formação: os outros só veem a formação de quando
	     chegaram.
	  3. Acaba a preparação: todos veem a formação de verdade, contagem de CountdownTime e a luta.

	Formação (cada time olhando para o centro): 1 = esquerda, 2 = meio, 3 = direita. No começo da luta cada um tem o
	alvo marcado: a esquerda luta com a direita do time da esquerda (na frente do portão entre os dois) e o meio luta
	com o meio do time da frente, no centro (os 4 do meio ficam perto: golpe em área pega mais de um). Cada par anda
	até o meio do caminho. Quando o alvo cai: inimigo colado (AttackRange) → bate nele sem andar; senão vai para a vaga
	livre mais perto que fica colada no inimigo mais perto (a vaga fica marcada assim que ele decide). Regras de golpe
	iguais às da Torre (Server/Combat/BattleEngine), com tempo em segundos (Server/Combat/ArenaEngine).
	Distâncias em studs a partir do centro do Coliseu; tempos em segundos.
]]

local ArenaBattleConfig = {
	MaxPlayers = 4,
	-- Todo brainrot da Arena luta no nível FixedLevel (12/11/2026, pedido do usuário): o que muda a força é o resto
	-- (estrelas, talento, tamanho, artefato e a árvore de skills); os robôs também
	FixedLevel = 50,
	-- Arena equalizada (16/11/2026, pedido do usuário): todos (jogadores e robôs) sem estrelas, com este tamanho (%) e este
	-- talento atual em Vida, Ataque e Velocidade. Artefatos e árvore de skills continuam valendo
	FixedStars = 0,
	FixedSize = 50,
	FixedTalent = 50,
	LobbyTime = 20, -- círculos verdes no centro (12/11/2026, pedido do usuário: era 60)
	PrepTime = 10, -- arrumar a formação (16/11/2026, pedido do usuário: era 15)
	CountdownTime = 3, -- contagem com a formação de verdade (16/11/2026, pedido do usuário: era 5)
	EndHold = 6, -- depois do último golpe: faixa do vencedor, antes dos prêmios e de soltar todo mundo
	-- 13/11/2026 (Coliseu 50% maior, pedido do usuário): TODAS as medidas da Arena × 1,5 (círculos, lugares, alcances,
	-- arquibancada, câmera, velocidade de andar e o tamanho dos brainrots, UnitScale), para a luta ficar igual na tela.
	-- Os números antigos estão no fim de cada linha
	-- Círculo da entrada (o mesmo efeito da Máquina de Vendas e do Cofre: Client/AreaRingController). O tapete fica com
	-- o topo um pouco acima do emblema do centro (5,17): o disco desenhado não fica no mesmo plano de nada
	-- WallHeight/WallBottom (18/11/2026): parede de luz levantada igual à da área do Vulcão (EventConfig Volcano.Zone)
	Ring = { Radius = 18, Color = Color3.fromRGB(85, 222, 120), PadTop = 5.33, WallHeight = 5, WallBottom = 0.35 }, -- 12 e 3,55
	-- Os dois círculos (12/11/2026): deslocamento do centro do Coliseu (x, z); a Arena 1 fica à esquerda de quem entra
	-- pela porta norte (olhando para o sul, +Z: a esquerda é +X). Label = placa em cima do círculo
	Rings = {
		{ Offset = Vector3.new(21, 0, 0), Label = "ARENA 1" }, -- 14
		{ Offset = Vector3.new(-21, 0, 0), Label = "ARENA 2" },
	},
	RingLabelHeight = 10.5, -- placa "ARENA N" acima do círculo (7)
	BusyTextHeight = 9, -- "Batalha da arena N em andamento", acima do chão no meio do Coliseu (6)

	-- Times = as 4 arquibancadas coloridas (ângulo de bússola do meio dela, visto do centro: 0 = norte, 90 = leste)
	Teams = {
		{ Side = "A", Angle = 45, Name = "Verde", Color = Color3.fromRGB(120, 215, 120) },
		{ Side = "B", Angle = 135, Name = "Vermelho", Color = Color3.fromRGB(240, 105, 85) },
		{ Side = "C", Angle = 225, Name = "Azul", Color = Color3.fromRGB(100, 170, 240) },
		{ Side = "D", Angle = 315, Name = "Amarelo", Color = Color3.fromRGB(245, 200, 70) },
	},

	-- Lugares no piso
	-- a fila de cada time, na frente da arquibancada (08/11/2026: 25,5 → 22 e 7 → 6, pedido do usuário: os das pontas
	-- ficavam atrás das pilastras dos cantos do Coliseu)
	FormationRadius = 33, -- 22
	FormationSpacing = 9, -- entre os 3 da fila (6)
	CornerGap = 9, -- distância entre os dois do par do portão (6)
	CornerSpotInward = 8.25, -- vaga do lado de cada um do par do portão, para o lado do centro (5,5)
	CenterRadius = 5.25, -- os 4 do meio, do centro até cada um (3,5)
	CenterSpotRadius = 9.3, -- as 4 vagas do centro (na direção dos portões), cada uma colada em 2 do meio (6,2)
	AttackRange = 11.25, -- colado: dá para bater sem andar (7,5)
	AreaRadius = 12.75, -- golpe em área pega os inimigos até aqui de quem bate (8,5)
	UnitScale = 1.5, -- tamanho dos brainrots na Arena (1)
	FloorLift = 0.05, -- o anel do time fica isto acima do chão de verdade (nada no mesmo plano)

	-- Arquibancada: o avatar fica em pé na fileira colorida da frente (Row2); a câmera fica atrás e acima dele (pela
	-- foto de referência do usuário: o avatar embaixo no meio, os 3 brainrots dele logo acima, a arquibancada da frente
	-- em cima). Distance/LookRadius = do centro do Coliseu, na direção da arquibancada
	Stand = { Radius = 53.25, FeetY = 8.46 }, -- 35,5 e 5,64 (medido no Studio: topo da Row2)
	-- (a parede de fora fica em 73,5–75,75 do centro, até 43,5 de altura: a câmera fica na frente dela)
	-- 08/11/2026: a câmera que o usuário deixou no Studio (mais alta: 44,2 do centro, 31,6 de altura, 39° para baixo);
	-- 13/11/2026 × 1,5 (era Distance 44,2, Height 31,6, LookRadius 9,3, LookHeight 3)
	Camera = { Distance = 66.3, Height = 47.4, LookRadius = 13.95, LookHeight = 4.5, Fov = 70 },
	QuickLobbyTime = 10, -- botão DEV "Arena rápida": círculo curto para testar

	-- Ritmo da luta
	-- Vida de todos na Arena × isto (igual para todos: não muda quem é mais forte; com a Vida da Torre a luta acabava em
	-- ~15 s e quase não dava para ver ninguém trocar de lugar). Escudos e curas em % da Vida crescem junto
	HpMultiplier = 2,
	-- Ritmo dos ataques: CombatConfig.RealtimeAttack (500 de Velocidade = 1/s, 2500 = 1,8/s; igual na briga do Coliseu)
	WalkSpeed = 21, -- studs/s andando entre os lugares (14)
	SettleTime = 0.15, -- chegou num lugar: espera isto antes de bater
	ReactionTime = 0.45, -- o alvo caiu: decide para onde ir depois disto
	-- Trocar de alvo (15/11/2026, pedido do usuário): alguém de fora bateu SwitchAfterHits golpes neste brainrot e tem
	-- menos Vida atual que o alvo dele → passa a bater em quem está batendo nele (ArenaEngine provoke)
	SwitchAfterHits = 2,
	RetryTime = 0.6, -- sem vaga livre perto de ninguém: tenta de novo depois disto
	RecoverTime = 0.5, -- do último golpe do turno até poder começar o próximo
	-- Entre um golpe e o próximo do mesmo turno (a pancada 2 e 3 do Tung seguem as animações: Shared/Brainrot/ComboTiming)
	StrikeGap = { Attack = 0.45, Blow = 0.32, Extra = 0.45, Counter = 0.3 },
	-- Za Warudo: o tempo do mundo para; os golpes dele saem dentro desta parada
	-- 13/11/2026 (pedido do usuário): 0,5 s parado, 4 golpes a cada 0,25 s e acaba em 1,5 s (era 1,1 / 0,45 / 0,5)
	TimeStop = { Intro = 0.5, Gap = 0.25, Outro = 0.25 },
	MaxSeconds = 150, -- tempo máximo da luta (do mundo); chegou nele, vence o time com mais % de Vida
	-- "1 turno" das habilidades = isto em segundos na Arena (13/11/2026, pedido do usuário): atordoamento, lentidão,
	-- fraqueza e arrancada duram turnos × TurnSeconds; queimadura, cura por turno e fúria batem a cada TurnSeconds
	TurnSeconds = 2.5, -- 13/11/2026 (pedido do usuário): era 4
	-- Morte súbita (13/11/2026, pedido do usuário): aos Start s o dano de todos sobe Bonus (+300%), e a cada Every s
	-- depois sobe mais Bonus (32 s = +300%, 42 s = +600%...); a tela mostra Text toda vez. 14/11/2026 (pedido do
	-- usuário): Start 8 s mais cedo (era 40)
	Overtime = { Start = 32, Every = 10, Bonus = 3, ShowSeconds = 2.5 },
	EndTail = 1.2, -- depois do último evento do roteiro

	-- Robôs nas vagas que sobram
	Bots = {
		Name = "Robô",
		-- Cores do avatar padrão clássico (cabeça e braços amarelos, tronco azul, pernas verdes)
		HeadColor = Color3.fromRGB(245, 205, 48),
		TorsoColor = Color3.fromRGB(13, 105, 172),
		LegColor = Color3.fromRGB(164, 189, 71),
	},

	-- Prêmios (12/11/2026, no molde do Rei da Colina): o 1º lugar ganha diamantes de DiamondsMin a DiamondsMax (pelo
	-- nível do brainrot mais alto do jogador, 1 a 200; Server/Events/Reward.byTopLevel) + VaultShare do limite do Cofre
	-- em moedas (com o multiplicador). Os outros lugares ganham a fração PlaceShares disso. Robôs não ganham nada.
	-- 12/11/2026 (pedido do usuário): 250–1.500 💎 e 300% do Cofre para o 1º; 2º 40%, 3º 25%, 4º 10% disso
	-- 13/11/2026 (pedido do usuário): 250–700 💎 (era 250–1.500), Cofre igual
	Reward = { DiamondsMin = 250, DiamondsMax = 700, VaultShare = 3 },
	PlaceShares = { 1, 0.4, 0.25, 0.1 } :: { number },
	-- 14/11/2026 (pedido do usuário): o Reward acima é o de 1 jogador contra 3 robôs; cada jogador de verdade a mais na
	-- MESMA luta soma +40% no prêmio de todos (2 jogadores = 1,4x, 3 = 1,8x, 4 = 2,2x)
	PerExtraPlayer = 0.4,
}

return ArenaBattleConfig
]=]
SOURCES["src/shared/Config/ArtifactConfig.luau"] = [=[
--[[
	ArtifactConfig — artefatos: itens que o jogador equipa nos brainrots (08/11/2026, pedido do usuário). Desde 14/11/2026
	DOIS por brainrot: campos Artifact e Artifact2 (SlotFields); somar sempre pelos *Of(brainrot) (effectsOf, statBonusOf,
	xpBonusOf, equipped), nunca pelo brainrot.Artifact direto.

	Cada artefato existe em uma versão por raridade (id = "<Base>_<Raridade>", ex.: "GoldenApple_Mythic").
	  Stats   = +% no total de um stat, antes da árvore de skills: { Spd = 0.2 } = +20% de Velocidade (BrainrotStats)
	  Effects = efeitos de luta no mesmo formato das passivas (SpeciesConfig), com Silent = true e Name = o que aparece
	            na tela. Crit/Lifesteal/DamageReduction/Dodge/Reflect já entram na lista de stats (Client/UI/FullStats)

	Imagens: pixel art do usuário, separada em camadas por tools/paint_artifacts.py (assets/ui/artifacts).
	O slot é montado em camadas (Client/UI/ArtifactSlot): moldura limpa + risco (branco, tingido pela raridade) + ícone.
	O ícone é igual em todas as raridades (pedido do usuário); no Prismático o risco e o ícone animam em arco-íris pela
	engine (RarityPaint, como os nomes dos brainrots), sem imagem a mais.
]]

local RarityConfig = require(script.Parent.RarityConfig)

export type Artifact = {
	Id: string,
	Base: string,
	Rarity: string,
	Name: string,
	Image: string,
	BorderCell: number?, -- célula da borda na folha (ArtifactConfig.BorderSheet; nil = fica a borda preta do ícone)
	Description: string,
	ValueText: string?, -- o número em texto ("6%")
	Note: string?, -- adendo, em itálico numa linha à parte (ArtifactConfig.fullDescription)
	Stats: { [string]: number }?,
	XpBonus: number?, -- +% da Aura no fim da luta (Olho de Ha'gna)
	Effects: { [string]: any },
}

local ArtifactConfig = {}

-- Ids do Roblox
ArtifactConfig.Images = {
	Slot = "rbxassetid://124377206860872",
	Scribble = "rbxassetid://74432485849668",
	-- 19/11/2026: todos sem o contorno preto (pedido do usuário)
	Apple = "rbxassetid://137339861808120",
	-- 13/11/2026: pixel arts 16x16 do usuário, pelo tools/paint_artifacts.py (mesmo processo da maçã)
	Heart = "rbxassetid://88930339527818",
	Arrow = "rbxassetid://131027699291232",
	Dagger = "rbxassetid://111077002478596",
	Trident = "rbxassetid://71976401893824",
	Boots = "rbxassetid://85642606988403",
	Eye = "rbxassetid://127890104191348",
	Chestplate = "rbxassetid://88197389377392",
	Scythe = "rbxassetid://71338390619864", -- Lâmina de Dante (13/11/2026)
	Crystal = "rbxassetid://104910863032523", -- Jakalopita (13/11/2026)
	Judgment = "rbxassetid://134101292701161", -- Julgamento de Eyros (14/11/2026)
	Wine = "rbxassetid://94777987850343", -- Vinho de Pedro (14/11/2026)
	Cactus = "rbxassetid://121734954284664", -- Cacto (14/11/2026)
	Torch = "rbxassetid://114037802639182", -- Chamas de Goes (15/11/2026; desenho novo do usuário, antes 119822677756433)
	-- Bordas dos ícones numa folha só (BorderSheet.png, tools/paint_artifacts.py; 13/11/2026: o Roblox travou 7 das 8
	-- imagens separadas na análise). Cada artefato usa a célula dele (ArtifactConfig.BorderSheet)
	-- 14/11/2026: 4x4, com a borda do Cacto (antes 132770647789649, 4x3; e 104589689347536)
	-- 15/11/2026: com a borda das Chamas de Goes, célula 13 (antes 81886088491597)
	BorderSheet = "rbxassetid://101563479881128",
}

-- Os mesmos ícones COM o contorno preto (os de antes de 19/11/2026): só na mochila/artefatos no modo escuro
-- (Client/UI/DarkMode troca a imagem)
ArtifactConfig.OutlinedImages = {
	Apple = "rbxassetid://72063993901111",
	Heart = "rbxassetid://77299843576037",
	Arrow = "rbxassetid://122215941966098",
	Dagger = "rbxassetid://125865603236393",
	Trident = "rbxassetid://112096163602178",
	Boots = "rbxassetid://109725939089540",
	Eye = "rbxassetid://114918513561219",
	Chestplate = "rbxassetid://91315538358891",
	Scythe = "rbxassetid://85893180211905",
	Crystal = "rbxassetid://79282823538369",
	Judgment = "rbxassetid://106642617706351",
	Wine = "rbxassetid://136574126135459",
	Cactus = "rbxassetid://100732426473437",
	Torch = "rbxassetid://79441340168884",
}

-- Folha das bordas: 4 colunas, células de 160 pixels (20 pixels da arte x 8), na ordem do tools/paint_artifacts.py
-- Cobrir o contorno preto do ícone com a folha de bordas na cor do fundo (desligado em 18/11/2026: virava borda branca)
ArtifactConfig.CoverIconOutline = false

ArtifactConfig.BorderSheet = {
	Columns = 4,
	Cell = 160,
	Cells = {
		Apple = 0,
		Heart = 1,
		Arrow = 2,
		Dagger = 3,
		Trident = 4,
		Boots = 5,
		Eye = 6,
		Chestplate = 7,
		Scythe = 8,
		Crystal = 9,
		Judgment = 10,
		Wine = 11,
		Cactus = 12,
		Torch = 13,
	},
}

-- O usuário ainda não decidiu se o slot vazio tem o risco no fundo: false = usa a moldura limpa
ArtifactConfig.ShowEmptyScribble = true
ArtifactConfig.EmptyScribbleColor = Color3.fromRGB(15, 16, 15)
-- Cor do número flutuante do dano extra da Jakalopita (MaxHpHit), igual em toda tela: luta, Arena e briga (13/11/2026)
ArtifactConfig.MaxHpHitColor = Color3.fromRGB(196, 96, 255)
-- Jakalopita contra o Chefão do rodízio (TowerBossConfig; 15/11/2026, pedido do usuário): só esta fração do dano extra
-- (TowerService põe MaxHpHitShare no chefe). Os chefes da Torre levam o dano inteiro
ArtifactConfig.MaxHpHitBossShare = 0.4 -- 20/11/2026 (pedido do usuário): 60% menos; era 0.5
-- Jakalopita na Piñata (16/11/2026, pedido do usuário): Percent × isto do dano de cada golpe, à parte (2% → +10%)
ArtifactConfig.MaxHpHitPinataMultiplier = 5
-- Cor do número do dano extra do Julgamento de Eyros (FirstStrike; 14/11/2026, pedido do usuário: amarelo)
ArtifactConfig.FirstStrikeColor = Color3.fromRGB(255, 225, 40)
-- Cor do número do dano dos espinhos (Cacto e passivas Reflect; 15/11/2026, pedido do usuário): branco com 🌵 do lado,
-- igual em toda luta (Torre/PvP, Arena e briga do Coliseu)
ArtifactConfig.ThornsColor = Color3.fromRGB(255, 255, 255)
-- Julgamento (14/11/2026, pedido do usuário): vale no 1º turno inteiro; golpe de habilidade ou em área ganha só esta
-- fração do extra (o ataque básico num alvo, o extra inteiro; BattleEngine/BrawlSkills strike)
ArtifactConfig.FirstStrikeAreaShare = 0.33
-- Transparência do ícone no slot enquanto o mouse está em cima de um artefato (prévia)
ArtifactConfig.PreviewTransparency = 0.45

-- Cor do risco do slot por raridade (o Mítico é a cor exata da imagem do usuário; o Prismático anima, ver RarityPaint)
ArtifactConfig.ScribbleColors = {
	Common = Color3.fromRGB(143, 143, 143),
	Uncommon = Color3.fromRGB(67, 168, 76),
	Rare = Color3.fromRGB(50, 118, 214),
	Epic = Color3.fromRGB(143, 67, 193),
	Legendary = Color3.fromRGB(214, 143, 25),
	Mythic = Color3.fromRGB(215, 44, 44),
}

local APPLE_NAME = "Maçã Dourada"
local APPLE_HITS = 4 -- 14/11/2026 (pedido do usuário): a cada 4 ataques (era 3)
-- Cura de cada raridade. 14/11/2026 (pedido do usuário): Prismático 7% (era 10%) e as outras na mesma proporção
-- (× 0,7, de meio em meio; eram 2/3/4/5/6,5/8%)
-- 15/11/2026 (pedido do usuário): passo de 0,75 de Comum a Mítico e o dobro (1,5) do Mítico para o Prismático
local APPLE_HEAL = {
	Common = 0.0175,
	Uncommon = 0.025,
	Rare = 0.0325,
	Epic = 0.04,
	Legendary = 0.0475,
	Mythic = 0.055,
	Secret = 0.07,
}

local list: { Artifact } = {}
local byId: { [string]: Artifact } = {}

for _, rarity in RarityConfig.List do
	local heal = APPLE_HEAL[rarity.Id]
	if heal then
		-- "1,75", "2,5" ou "4" (com vírgula, sem zero à toa no fim)
		local percent = math.floor(heal * 10000 + 0.5) / 100
		local percentText = if percent % 1 == 0
			then string.format("%d", percent)
			else (string.format("%.2f", percent):gsub("0+$", ""):gsub("%.", ","))
		local artifact: Artifact = {
			Id = `GoldenApple_{rarity.Id}`,
			Base = "GoldenApple",
			Rarity = rarity.Id,
			Name = APPLE_NAME,
			Image = ArtifactConfig.Images.Apple,
			BorderCell = ArtifactConfig.BorderSheet.Cells.Apple,
			Description = `Cura {percentText}% da Vida a cada {APPLE_HITS} ataques causados ou recebidos.`,
			Effects = {
				{ Type = "HealEveryHits", Percent = heal, Every = APPLE_HITS, Name = APPLE_NAME, Silent = true },
			},
		}
		table.insert(list, artifact)
		byId[artifact.Id] = artifact
	end
end

-- Artefatos de stat (13/11/2026, pedido do usuário): de Comum a Prismático, em linha reta e arredondado.
--   Stat   = +% no total do stat (Hp/Atk/Spd, campo Stats)
--   Effect = efeito de luta (Silent) com o valor em Field: crítico e esquiva = Chance (o crítico usa o multiplicador
--            base); escudo = Percent da Vida máxima no começo da luta
--   Xp     = +% da Aura que o brainrot ganha no fim da luta (campo XpBonus; Server/Services/TowerService)
-- 15/11/2026 (pedido do usuário): mesmo passo de Comum a Mítico e o dobro do Mítico para o Prismático, de meio em meio
local STAT_STEPS =
	{ Common = 0.06, Uncommon = 0.08, Rare = 0.1, Epic = 0.12, Legendary = 0.14, Mythic = 0.16, Secret = 0.2 }
-- Tridente (Ataque; 14/11/2026, pedido do usuário): Prismático 16% (era 20%, o STAT_STEPS) e os outros mais baixos junto
-- 15/11/2026 (pedido do usuário): mesmo passo de Comum a Mítico e o dobro do Mítico para o Prismático, de meio em meio
-- 20/11/2026 (pedido do usuário): Prismático 24%, mesma regra; passo 3 (Comum 3%). Era 2/4/6/8/10/12/16
-- 20/11/2026 (pedido do usuário, o Comum tinha ficado baixo demais): Comum 8% e Prismático 22%, mesma regra; passo 2.
-- Era 3/6/9/12/15/18/24
local ATTACK_STEPS =
	{ Common = 0.08, Uncommon = 0.1, Rare = 0.12, Epic = 0.14, Legendary = 0.16, Mythic = 0.18, Secret = 0.22 }
-- Esquiva (Bambu): 3% (Comum) a 15% (Prismático), de 2 em 2 (13/11/2026, pedido do usuário; era 2% a 10%)
-- 15/11/2026 (pedido do usuário): mesmo passo de Comum a Mítico e o dobro do Mítico para o Prismático, de meio em meio
-- 20/11/2026 (pedido do usuário): Prismático 18%, mesma regra; passo 2 (Comum 4%). Era 4,5/6/7,5/9/10,5/12/15
local DODGE_STEPS =
	{ Common = 0.04, Uncommon = 0.06, Rare = 0.08, Epic = 0.1, Legendary = 0.12, Mythic = 0.14, Secret = 0.18 }
-- Sapatos do Fred (Velocidade; 20/11/2026, pedido do usuário): Prismático 24%, mesma regra; passo 2,5 (Comum 6,5%).
-- Era o STAT_STEPS (6 a 20%)
-- 20/11/2026 (pedido do usuário): Comum 9%, Prismático 24% igual; passo 2 e salto 5 (o exato daria 2,14). Era 6,5 a 24
local SPEED_STEPS =
	{ Common = 0.09, Uncommon = 0.11, Rare = 0.13, Epic = 0.15, Legendary = 0.17, Mythic = 0.19, Secret = 0.24 }
-- Flecha Certeira (crítico; 20/11/2026, pedido do usuário): Prismático 28%, mesma regra; passo 3 (Comum 7%).
-- Era o STAT_STEPS (6 a 20%)
-- 20/11/2026 (pedido do usuário): Comum 10%, Prismático 28% igual; passo 2,5 e salto 5,5 (o exato daria 2,57). Era 7 a 28
local CRIT_STEPS =
	{ Common = 0.1, Uncommon = 0.125, Rare = 0.15, Epic = 0.175, Legendary = 0.2, Mythic = 0.225, Secret = 0.28 }
-- Escudo: linha reta de 2% (Comum) a 10% (Mítico) e um pulo para 12% no Prismático (pedido do usuário)
-- 15/11/2026 (pedido do usuário): mesmo passo de Comum a Mítico e o dobro do Mítico para o Prismático, de meio em meio
local SHIELD_STEPS =
	{ Common = 0.015, Uncommon = 0.03, Rare = 0.045, Epic = 0.06, Legendary = 0.075, Mythic = 0.09, Secret = 0.12 }
-- Roubo de vida (Lâmina de Dante; 13/11/2026, pedido do usuário): 2% (Comum) a 12% (Prismático), como o escudo
-- 15/11/2026 (pedido do usuário): mesmo passo de Comum a Mítico e o dobro do Mítico para o Prismático, de meio em meio
local LIFESTEAL_STEPS =
	{ Common = 0.02, Uncommon = 0.04, Rare = 0.06, Epic = 0.08, Legendary = 0.1, Mythic = 0.12, Secret = 0.16 }
-- Jakalopita (13/11/2026, pedido do usuário: 0,5% no Comum e 4% no Prismático; o meio é escolha minha, crescendo
-- devagar no começo): % da Vida MÁXIMA do alvo de dano extra em todo golpe que acerta (efeito MaxHpHit; motor da luta,
-- Arena e briga; número roxo à parte, ArtifactConfig.MaxHpHitColor)
-- 15/11/2026 (pedido do usuário): Prismático 4% → 3% e o meio refeito (era 0,75/1/1,5/2/3)
-- 15/11/2026 (pedido do usuário): passo de 0,25 (com 0,5 o Comum ficaria abaixo de zero) e o dobro no Prismático
local MAX_HP_HIT_STEPS =
	{ Common = 0.0125, Uncommon = 0.015, Rare = 0.0175, Epic = 0.02, Legendary = 0.0225, Mythic = 0.025, Secret = 0.03 }
-- Julgamento de Eyros (14/11/2026, pedido do usuário; só de Épico para cima): o PRIMEIRO golpe do brainrot na luta
-- dá um dano extra à parte = Percent × o Ataque dele (efeito FirstStrike; não aumenta o golpe; número amarelo,
-- ArtifactConfig.FirstStrikeColor)
-- 20/11/2026 (pedido do usuário): em todas as raridades, 50% (Comum) a 200% (Prismático), mesmo passo de Comum a Mítico
-- e o dobro do Mítico para o Prismático. A conta exata dá passo de 21,43; de meio em meio: passo 21,5 e salto de 42,5.
-- Era só Épico 100 / Lendário 150 / Mítico 200 / Prismático 300
-- 20/11/2026 (pedido do usuário): sem Comum (era 50%); raridade sem número aqui não existe
-- 20/11/2026 (pedido do usuário): de novo só de Épico para cima, 80/120/160/225 (era Incomum 71,5 a Prismático 200)
local FIRST_STRIKE_STEPS = {
	Epic = 0.8,
	Legendary = 1.2,
	Mythic = 1.6,
	Secret = 2.25,
}
-- Vinho de Pedro (14/11/2026, pedido do usuário): redução de dano de 3% (Comum) a 12% (Prismático), em linha reta
-- 15/11/2026 (pedido do usuário): mesmo passo de Comum a Mítico e o dobro do Mítico para o Prismático, de meio em meio
-- 20/11/2026 (pedido do usuário): Prismático 18%, mesma regra; passo 2 (Comum 4%). Era 1,5/3/4,5/6/7,5/9/12
-- 20/11/2026 (pedido do usuário): Comum 8%, Prismático 18% igual; passo 1,5 e salto 2,5 (o exato daria 1,43). Era 4 a 18
local REDUCTION_STEPS =
	{ Common = 0.08, Uncommon = 0.095, Rare = 0.11, Epic = 0.125, Legendary = 0.14, Mythic = 0.155, Secret = 0.18 }
-- Cacto (14/11/2026, pedido do usuário): espinhos de 6% (Comum) a 30% (Prismático), de 4 em 4 (efeito Reflect: do dano
-- recebido volta em quem bateu). 15/11/2026 (pedido do usuário): Prismático 50% e depois de volta a 30%
-- 15/11/2026 (pedido do usuário): mesmo passo de Comum a Mítico e o dobro do Mítico para o Prismático, de meio em meio
-- 20/11/2026 (pedido do usuário): 8% (Comum) a 24% (Prismático), mesma regra. A conta exata dá passo de 2,29; de 0,25 em
-- 0,25 (de meio em meio não fecha): passo 2,25 e salto de 4,75. Era 9/12/15/18/21/24/30
local THORNS_STEPS = {
	Common = 0.08,
	Uncommon = 0.1025,
	Rare = 0.125,
	Epic = 0.1475,
	Legendary = 0.17,
	Mythic = 0.1925,
	Secret = 0.24,
}
-- Chamas de Goes (15/11/2026, pedido do usuário: 10% no Comum e 65% no Prismático; o meio é escolha minha, quase em
-- linha reta): penetração de escudo E de redução de dano, o mesmo número nas duas (efeito Pierce, BattleEngine/BrawlSkills)
--   escudo: esta fração do golpe vai direto na Vida, o resto no escudo (16/11/2026: 40% = 40% na Vida, 60% no escudo)
--   redução: tira esta fração da redução de dano do alvo (10% de redução e 40% de penetração = 6%)
-- 16/11/2026 (pedido do usuário): 15% no Comum e 40% no Prismático; o meio é escolha minha, de 4 em 4
-- 18/11/2026 (pedido do usuário): a de ESCUDO é só 2/3 desse número, arredondado para o % inteiro mais perto
-- (PIERCE_SHIELD_SCALE + scaled; 40% → 27%)
local PIERCE_STEPS =
	{ Common = 0.15, Uncommon = 0.19, Rare = 0.23, Epic = 0.27, Legendary = 0.31, Mythic = 0.35, Secret = 0.4 }
local PIERCE_SHIELD_SCALE = 2 / 3

-- value × scale arredondado para o % inteiro mais perto (0,1533 → 0,15)
local function scaled(value: number, scale: number): number
	return math.floor(value * scale * 100 + 0.5) / 100
end
-- Aura: 6% (Comum) a 30% (Prismático), de 4 em 4
-- 15/11/2026 (pedido do usuário): mesmo passo de Comum a Mítico e o dobro do Mítico para o Prismático, de meio em meio
local XP_STEPS =
	{ Common = 0.09, Uncommon = 0.12, Rare = 0.15, Epic = 0.18, Legendary = 0.21, Mythic = 0.24, Secret = 0.3 }
local STAT_ARTIFACTS = {
	-- 13/11/2026 (pedido do usuário): a Vida passou da Carapaça para o Peitoral; a Carapaça dá escudo (o id continua Heart)
	{ Base = "Chestplate", Name = "Peitoral de Gripp", Image = "Chestplate", Stat = "Hp", Text = "de Vida" },
	{
		Base = "Heart",
		Name = "Carapaça de Dziga",
		Image = "Heart",
		Effect = "Shield",
		Field = "Percent",
		Steps = SHIELD_STEPS,
		Text = "da Vida de escudo no começo da luta",
	},
	{
		Base = "Arrow",
		Name = "Flecha Certeira",
		Image = "Arrow",
		Effect = "Crit",
		Steps = CRIT_STEPS,
		Text = "de chance de crítico",
	},
	{
		Base = "Dagger",
		Name = "Bambu", -- 13/11/2026 (pedido do usuário): era "Adaga Esquiva" (o id continua Dagger)
		Image = "Dagger",
		Effect = "Dodge",
		Steps = DODGE_STEPS,
		Text = "de chance de esquivar",
	},
	{
		Base = "Trident",
		Name = "Tridente Feroz",
		Image = "Trident",
		Stat = "Atk",
		Steps = ATTACK_STEPS,
		Text = "de Ataque",
	},
	-- 14/11/2026 (pedido do usuário): era "Botas Ligeiras" (o id continua Boots)
	{
		Base = "Boots",
		Name = "Sapatos do Fred",
		Image = "Boots",
		Stat = "Spd",
		Steps = SPEED_STEPS,
		Text = "de Velocidade",
	},
	{
		Base = "Eye",
		Name = "Olho de Ha'gna",
		Image = "Eye",
		Xp = true,
		Steps = XP_STEPS,
		Text = "de Aura no fim de cada luta",
	},
	{
		Base = "Scythe",
		Name = "Lâmina de Dante",
		Image = "Scythe",
		Effect = "Lifesteal",
		Field = "Percent",
		Steps = LIFESTEAL_STEPS,
		Text = "do dano causado vira Vida",
	},
	{
		Base = "Crystal",
		Name = "Jakalopita",
		Image = "Crystal",
		Effect = "MaxHpHit",
		Field = "Percent",
		Steps = MAX_HP_HIT_STEPS,
		-- 14/11/2026 (pedido do usuário): deixar claro que vale em ataques E habilidades
		Text = "da Vida máxima do alvo de dano extra a cada golpe, em ataques e habilidades",
		Note = "Tem 40% de eficácia contra super chefões.",
	},
	{
		Base = "Judgment",
		Name = "Julgamento de Eyros",
		Image = "Judgment",
		Effect = "FirstStrike",
		Field = "Percent",
		Steps = FIRST_STRIKE_STEPS,
		Describe = function(text: string): string
			return `Durante seu primeiro turno, seus danos causam um extra de {text}% do seu Ataque. Habilidades e dano em área têm 33% de eficácia.`
		end,
	},
	{
		Base = "Wine",
		Name = "Vinho de Pedro",
		Image = "Wine",
		Effect = "DamageReduction",
		Field = "Percent",
		Steps = REDUCTION_STEPS,
		Text = "de redução de dano",
	},
	{
		Base = "Cactus",
		Name = "Cacto",
		Image = "Cactus",
		Effect = "Reflect",
		Field = "Percent",
		Steps = THORNS_STEPS,
		Text = "de espinhos",
		Describe = function(text: string): string
			-- 18/11/2026 (pedido do usuário): duas linhas
			return `+{text}% de espinhos\n{text}% do golpe que você leva volta para o atacante` -- 19/11/2026: sem a linha da redução de dano (pedido do usuário)
		end,
	},
	{
		Base = "Torch",
		Name = "Chamas de Goes",
		Image = "Torch",
		Effect = "Pierce",
		Fields = { "ShieldPierce", "ReductionPierce" },
		FieldScale = { ShieldPierce = PIERCE_SHIELD_SCALE },
		Steps = PIERCE_STEPS,
		-- format(número) = o texto de um número ("27"), para os campos com FieldScale
		Describe = function(text: string, value: number, format: (number) -> string): string
			-- 15/11/2026 (pedido do usuário): só as duas linhas
			return `+{format(scaled(value, PIERCE_SHIELD_SCALE))}% penetração de escudo\n+{text}% penetração de redução de dano`
		end,
	},
}

-- "4", "0,5" ou "0,75" (com vírgula, sem zero à toa no fim)
local function percentText(value: number): string
	local percent = math.floor(value * 10000 + 0.5) / 100
	if percent % 1 == 0 then
		return string.format("%d", percent)
	end
	local text = string.format("%.2f", percent):gsub("0+$", "")
	return (text:gsub("%.", ","))
end

-- Efeito de luta de um artefato: o número vai em Field (ou Chance); com Fields, o mesmo número em todos, × FieldScale
-- do campo arredondado para o % inteiro (Chamas de Goes: escudo = 2/3 da redução)
local function effectOf(kind: any, value: number): any
	local effect: any = { Type = kind.Effect, Name = kind.Name, Silent = true }
	for _, field in kind.Fields or { kind.Field or "Chance" } do
		local scale = (kind.FieldScale or {})[field]
		effect[field] = if scale then scaled(value, scale) else value
	end
	return effect
end

for _, kind: any in STAT_ARTIFACTS do
	for _, rarity in RarityConfig.List do
		local value = (kind.Steps or STAT_STEPS)[rarity.Id]
		if value then
			local artifact: Artifact = {
				Id = `{kind.Base}_{rarity.Id}`,
				Base = kind.Base,
				Rarity = rarity.Id,
				Name = kind.Name,
				Image = (ArtifactConfig.Images :: any)[kind.Image],
				BorderCell = ArtifactConfig.BorderSheet.Cells[kind.Image],
				Description = if kind.Describe
					then kind.Describe(percentText(value), value, percentText)
					else `+{percentText(value)}% {kind.Text}.`,
				-- O número do artefato em texto ("6%"), para a tabela por raridade no cartão (15/11/2026)
				ValueText = `{percentText(value)}%`,
				Note = kind.Note,
				Stats = if kind.Stat then { [kind.Stat] = value } else nil,
				XpBonus = if kind.Xp then value else nil,
				Effects = if kind.Effect then { effectOf(kind, value) } else {},
			}
			table.insert(list, artifact)
			byId[artifact.Id] = artifact
		end
	end
end

ArtifactConfig.List = list

function ArtifactConfig.get(id: string?): Artifact?
	return if id then byId[id] else nil
end

-- Descrição com o adendo (Note) numa linha à parte, em itálico: só em texto com RichText ligado
function ArtifactConfig.fullDescription(artifact: Artifact): string
	return if artifact.Note then `{artifact.Description}\n\n<i>{artifact.Note}</i>` else artifact.Description
end

-- Efeitos de luta do artefato (lista vazia se não tiver)
function ArtifactConfig.effects(id: string?): { [string]: any }
	local artifact = ArtifactConfig.get(id)
	return if artifact then artifact.Effects else {}
end

-- +% de Aura que o artefato dá no fim da luta (0 sem)
function ArtifactConfig.xpBonus(id: string?): number
	local artifact = ArtifactConfig.get(id)
	return if artifact then artifact.XpBonus or 0 else 0
end

-- +% do artefato num stat ("Hp", "Atk", "Spd")
function ArtifactConfig.statBonus(id: string?, key: string): number
	local artifact = ArtifactConfig.get(id)
	return if artifact and artifact.Stats then artifact.Stats[key] or 0 else 0
end

-- Dois artefatos por brainrot (14/11/2026, pedido do usuário): campo do brainrot de cada lugar. O 1º continua sendo o
-- "Artifact" de sempre (saves antigos valem sem migração)
ArtifactConfig.SlotFields = { "Artifact", "Artifact2" }

-- Campo do lugar `slot` (1 ou 2; qualquer outra coisa = 1)
function ArtifactConfig.slotField(slot: any): string
	return ArtifactConfig.SlotFields[if slot == 2 then 2 else 1]
end

-- Ids dos artefatos que o brainrot está usando, na ordem dos lugares (sem os vazios)
function ArtifactConfig.equipped(brainrot: any): { string }
	local ids = {}
	if brainrot then
		for _, field in ArtifactConfig.SlotFields do
			local id = brainrot[field]
			if ArtifactConfig.get(id) then
				table.insert(ids, id)
			end
		end
	end
	return ids
end

-- Artefatos em RichText para balões (16/11/2026, pedido do usuário: luta 1x1 e chefes da Torre): uma linha por
-- artefato, "🔮 Nome" na cor da raridade e o que ele faz; sem nenhum, `empty` (ou "")
function ArtifactConfig.richList(ids: { string }, empty: string?): string
	local lines = {}
	for _, id in ids do
		local artifact = ArtifactConfig.get(id)
		if artifact then
			table.insert(
				lines,
				`🔮 <b>{RarityConfig.richName(artifact.Rarity, artifact.Name)}</b>: {artifact.Description}`
			)
		end
	end
	return if #lines > 0 then table.concat(lines, "\n") else empty or ""
end

-- Efeitos de luta dos dois artefatos do brainrot juntos (lista nova)
function ArtifactConfig.effectsOf(brainrot: any): { [string]: any }
	local all = {}
	for _, id in ArtifactConfig.equipped(brainrot) do
		for _, effect in ArtifactConfig.effects(id) do
			table.insert(all, effect)
		end
	end
	return all
end

-- +% de Aura dos dois artefatos somados
function ArtifactConfig.xpBonusOf(brainrot: any): number
	local total = 0
	for _, id in ArtifactConfig.equipped(brainrot) do
		total += ArtifactConfig.xpBonus(id)
	end
	return total
end

-- +% dos dois artefatos somados num stat
function ArtifactConfig.statBonusOf(brainrot: any, key: string): number
	local total = 0
	for _, id in ArtifactConfig.equipped(brainrot) do
		total += ArtifactConfig.statBonus(id, key)
	end
	return total
end

-- Artefatos de um inimigo (robôs do PvP e inimigos da Torre; 15/11/2026): `count` (até 2) sorteados na raridade dada,
-- tipos diferentes, só os que fazem algo na luta (o Olho só dá Aura). `rng` = Random (sorteio igual no servidor e no
-- cliente); sem ele, math.random. Põe direto nos campos do brainrot.
function ArtifactConfig.equipRandom(brainrot: any, rarityId: string, count: number, rng: Random?)
	local pool = {}
	for _, artifact in list do
		local useful = artifact.Stats ~= nil or (artifact.Effects ~= nil and #artifact.Effects > 0)
		if artifact.Rarity == rarityId and useful then
			table.insert(pool, artifact)
		end
	end
	local slot, bases = 0, {}
	while slot < math.min(count, #ArtifactConfig.SlotFields) and #pool > 0 do
		local index = if rng then rng:NextInteger(1, #pool) else math.random(#pool)
		local artifact = table.remove(pool, index) :: Artifact
		if not bases[artifact.Base] then
			bases[artifact.Base] = true
			slot += 1
			brainrot[ArtifactConfig.SlotFields[slot]] = artifact.Id
		end
	end
end

return ArtifactConfig
]=]
SOURCES["src/shared/Config/BattleFxConfig.luau"] = [=[
--[[
	BattleFxConfig — cores, tempos e tamanhos dos efeitos visuais da luta e da briga.
	Tempos em segundos na velocidade 1x (o BattleController divide no 2x).
]]

local BattleFxConfig = {
	-- "+N Aura" de quem caiu e "NÍVEL N!" de quem subiu no meio da luta (15/11/2026, pedido do usuário): sobe devagar
	-- e reto, por cima de todos os números. Width = largura em studs (maior que os números de dano), Above = studs acima
	-- da cabeça, Rise = quanto sobe em Seconds, Fade = segundos do fim em que some
	-- FeetAbove = studs acima do pé (o "+N Aura" sai no pé de quem caiu; 16/11/2026, pedido do usuário)
	-- Aura = o "+N Aura" dura × Aura do tempo (sobe e some 40% mais rápido; 16/11/2026, pedido do usuário)
	RisePopup = {
		Width = 10,
		Above = 1.5,
		FeetAbove = 0.5,
		Rise = 2.5,
		Seconds = 2,
		Fade = 0.5,
		Aura = 0.6,
		Stagger = 2.5,
	},
	-- Texto das habilidades (16/11/2026, pedido do usuário: "🌳 RAÍZES!" e outros estavam enormes): todos do tamanho do
	-- "🍎 Maçã Dourada" de cada tela; só o 3º TUNG do Tung fica grande. Height = altura em studs do texto, Pixels =
	-- mínimo em pixels de longe (Arena). BattleFx.bigText usa o do visual (skillTextHeight/skillTextPixels)
	SkillText = {
		Battle = { Height = 1.3 }, -- Torre/PvP: o mesmo dos números e do nome da passiva (popup 5 x 1,3)
		Arena = { Height = 0.754, Pixels = 24 }, -- Arena (evento): popup 2,9 x 0,754 com mínimo de 24 px
		Brawl = { Height = 1.35 }, -- briga do Coliseu: skillText 4,5 x 1,35 (o da maçã)
	},
	-- Pulo na Cabeça do Chimpanzini (13/11/2026, pedido do usuário): sem animação, só a posição: Hops pulos em Seconds,
	-- cada um em arco de HopHeight studs, caindo em cima da cabeça do alvo (o dano sai em cada aterrissagem).
	-- BrawlLift = altura da cabeça do alvo de evento na briga (Patapim, piñata), que não tem modelo de brainrot
	-- Animation (13/11/2026, modelo do Chimpanzini do usuário): o começo do pulo, tocado a cada pulo (do chão e da cabeça
	-- do alvo) e solto quando ele volta para o lugar; modelo sem ela só pula
	HeadJump = { Hops = 3, Seconds = 1, HopHeight = 2.5, ReturnTime = 0.25, BrawlLift = 6, Animation = "power" },
	-- Explosão do golpe final do Tung (07/11/2026, sprite sheet do usuário: assets/fx/Explosion.png, 8 quadros de 70 px
	-- numa fileira). Duration = o total; Size em studs (luta / briga).
	Explosion = {
		Image = "rbxassetid://111103520057697",
		Frames = 8,
		FrameSize = 70,
		Duration = 0.4, -- 07/11/2026: era 0.6 (pedido do usuário)
		-- Quadros que a explosão começa antes da pancada (era 2, para o clarão do 3º quadro cair na hora dela; 08/11/2026:
		-- 0, o usuário via a explosão um pouco antes do dano e da paulada)
		LeadFrames = 0,
		GroundLift = 1, -- studs acima do chão embaixo do alvo (08/11/2026, pedido do usuário)
		Size = 12,
		BrawlSize = 10,
		BombSize = 14, -- bomba do Bombardiro (luta e briga)
	},
	Textures = {
		Sparkle = "rbxasset://textures/particles/sparkles_main.dds",
		Fire = "rbxasset://textures/particles/fire_main.dds",
		Smoke = "rbxasset://textures/particles/smoke_main.dds",
	},
	Ring = { Start = 1, End = 9, Time = 0.35, Thickness = 0.2 },
	-- Onda de choque do golpe final do Tung (13/11/2026, pedido do usuário: no lugar da explosão; BattleFx.shockwave):
	-- clarão no chão, 2 anéis abrindo, parede de poeira correndo para fora e pedrinhas voando
	Shockwave = {
		Reach = 11, -- raio (studs) que a onda alcança na luta
		BrawlReach = 9, -- na briga e na Arena
		FlashTime = 0.16,
		RingTime = 0.45,
		RingGap = 0.09, -- o 2º anel sai depois disto
		RingThickness = 0.14,
		Segments = 18, -- placas da parede de poeira
		WallHeight = 2.4,
		WallTime = 0.55,
		DustColor = Color3.fromRGB(214, 190, 150),
		Rocks = 9,
		RockColor = Color3.fromRGB(125, 98, 72),
		RockTime = 0.5,
		RockHeight = 2.5,
	},
	CameraShake = { Amplitude = 0.35, Step = 0.03 },
	TimeStop = {
		Shout = "ZA WARUDO!",
		-- Animação do modelo do Lirilì (14/11/2026, arquivo do usuário): tocada por cima do idle no grito; o relógio
		-- ataca de 0,55 a 1 s, junto com os 4 golpes (0,5 s + 4 × 0,25). Quem não tem a animação fica igual
		Animation = "za_warudo",
		SphereSize = 70,
		SphereTime = 0.45,
		GrayTime = 0.25,
		Saturation = -1,
		Contrast = 0.25,
		Tint = Color3.fromRGB(225, 255, 225),
		ResumeTime = 0.2,
		KnifeFlyTime = 0.12,
		PopupStagger = 0.05,
	},
	Freeze = { Color = Color3.fromRGB(150, 220, 255), Transparency = 0.4, Shards = 8 },
	Bombs = { PlaneHeight = 12, PlaneTime = 0.4, DropTime = 0.25 },
	-- Pneu da Boneca Ambalabu (Fx "TireRoll"): vira pneu ("power_in", que para no último quadro), rola por
	-- cima de todos os inimigos girando o osso "Tire" e volta rolando. SpinSign inverte o giro se rolar ao contrário.
	TireRoll = {
		Animation = "power_in",
		Bone = "Tire",
		RadiusStuds = 1.02, -- raio do pneu em studs com o modelo no tamanho normal (8 unidades × 0.128)
		SpinSign = -1,
		TransformTime = 0.45,
		TravelTime = 0.75,
		PastTarget = 3, -- studs depois do último inimigo
		ReturnTime = 0.6,
		Text = "🛞 ATROPELOU!",
		Color = Color3.fromRGB(70, 70, 80),
		BrawlTime = 1.2, -- na briga: quanto tempo fica de pneu girando
	},
	Bonk = { HitTime = 0.18, RingGrow = 1.4 },
	Execute = { Text = "EXECUÇÃO!", Color = Color3.fromRGB(255, 60, 60), DarkTime = 0.2 },
	Colors = {
		Ink = Color3.fromRGB(120, 60, 200),
		Zap = Color3.fromRGB(255, 240, 80),
		Thorns = Color3.fromRGB(90, 200, 90),
		Fire = Color3.fromRGB(255, 120, 40),
		Gold = Color3.fromRGB(255, 210, 80),
		Wave = Color3.fromRGB(70, 160, 255),
		Banana = Color3.fromRGB(255, 225, 60),
		Rose = Color3.fromRGB(255, 150, 200),
	},
	-- Efeito de cada habilidade: Color, Text (some se nil) e Shots (projéteis do dono até o alvo)
	Presets = {
		Zap = { Color = Color3.fromRGB(255, 240, 80), Text = "⚡ ZAP!", Shots = 2 },
		Gallop = { Color = Color3.fromRGB(235, 235, 235), Text = "🦓 GALOPE!" },
		Shell = { Color = Color3.fromRGB(170, 120, 70) },
		CocoShell = { Color = Color3.fromRGB(170, 120, 70) }, -- Casca de Coco nova do Burbaloni (19/11/2026), a mesma cor
		Bite = { Color = Color3.fromRGB(250, 245, 225), Text = "🦷 NHAC!" },
		Dash = { Color = Color3.fromRGB(90, 190, 255), Text = "⚡ ARRANCADA!" },
		Glitch = { Color = Color3.fromRGB(80, 255, 220), Text = "📵 SEM SINAL!" },
		Ice = { Color = Color3.fromRGB(170, 230, 255), Text = "🧊 GELOU!", Shots = 4 },
		Pierce = { Color = Color3.fromRGB(255, 225, 90), Text = "✏️ NA PONTA!", Shots = 1 },
		Whistle = { Color = Color3.fromRGB(255, 225, 70), Text = "PRIIII!" },
		Coffee = { Color = Color3.fromRGB(120, 72, 40), Text = "☕ DOPPIO!" },
		Block = { Color = Color3.fromRGB(220, 60, 60), Text = "🛡️ BLOQUEOU!" },
		Scan = { Color = Color3.fromRGB(255, 50, 50), Text = "🎯 ALVO!" },
		Stink = { Color = Color3.fromRGB(130, 190, 60), Text = "🤢 CHULÉ!", Shots = 3 },
		SweetSalty = { Color = Color3.fromRGB(255, 190, 215) },
		Splash = { Color = Color3.fromRGB(80, 180, 255), Text = "🐬 SPLASH!" },
		Float = { Color = Color3.fromRGB(190, 210, 255), Text = "🌌 FLUTUOU!" },
		Coconut = { Color = Color3.fromRGB(245, 245, 235) },
		Fire = { Color = Color3.fromRGB(255, 120, 40), Text = "🔥 QUEIMOU!", Shots = 2 },
		Gunshot = { Color = Color3.fromRGB(255, 225, 90), Text = "RATATÁ!", Shots = 5 },
		Gravity = { Color = Color3.fromRGB(190, 150, 255), Text = "🪐 GRAVIDADE!" },
		Dive = { Color = Color3.fromRGB(255, 255, 255), Text = "✈️ RASANTE!" },
		Rage = { Color = Color3.fromRGB(255, 70, 50), Text = "💪 FÚRIA!" },
		Chomp = { Color = Color3.fromRGB(110, 230, 110), Text = "🍉 NHAC!" },
		Swim = { Color = Color3.fromRGB(190, 225, 255), Text = "🐟 ESCAPOU!" },
		FishHeal = { Color = Color3.fromRGB(110, 240, 160), Text = "🐟 CUROU!" }, -- Trulimero (14/11/2026)
		StarHeal = { Color = Color3.fromRGB(150, 230, 255), Text = "🌌 CUROU!" }, -- Giraffa Celeste (17/11/2026)
		Roots = { Color = Color3.fromRGB(125, 85, 45), Text = "🌳 RAÍZES!" },
		Phoenix = { Color = Color3.fromRGB(255, 200, 70), Text = "✨ SETE VIDAS!" },
		Pirouette = { Color = Color3.fromRGB(255, 150, 200), Text = "🩰 PIRUETA!" },
		Banana = { Color = Color3.fromRGB(255, 225, 60), Text = "🍌 ESCORREGOU!" },
		ShieldPop = { Color = Color3.fromRGB(255, 210, 80), Text = "💥 ESTOUROU!" },
		TireBlast = { Color = Color3.fromRGB(255, 120, 40), Text = "💥 PNEU!" },
		-- Bobrito (15/11/2026): uma bala por golpe da rajada (a luta por turnos desenha à parte, BattleController)
		Burst = { Color = Color3.fromRGB(255, 225, 90), Text = "RATATÁ!", Shots = 1 },
		-- Bombombini (15/11/2026): napalm no inimigo com menos Vida (luta por turnos: BattleController napalmRun)
		Napalm = { Color = Color3.fromRGB(255, 110, 30), Text = "🔥 NAPALM!" },
	},
	-- Rajada do Bobrito na luta por turnos: tiros do lugar dele (sem andar), uma bala por golpe
	Burst = { Color = Color3.fromRGB(255, 225, 90), Text = "RATATÁ!", BulletSize = 0.35 },
	-- Napalm do Bombombini: voa até ficar em cima do alvo, solta a bomba (bola laranja) e volta; fogo no chão depois
	Napalm = {
		Color = Color3.fromRGB(255, 110, 30),
		Text = "🔥 NAPALM!",
		FlyHeight = 7,
		FlyTime = 0.5,
		DropHeight = 6,
		DropTime = 0.3,
		BombSize = 1.1,
		FireTime = 0.8, -- quanto tempo o fogo fica no chão embaixo do alvo
	},
	Shot = { Size = 0.6, Time = 0.22, Stagger = 0.04 },
	-- Briga no Coliseu (Parte D)
	Brawl = { RingEnd = 6, RingTime = 0.3, TextTime = 0.7, MaxPerSecond = 6 },
	-- Linha do tempo da luta: espécies cujo retrato mira no osso "head" do modelo (Viewport HeadBone) em vez de 78% da
	-- altura (14/11/2026, pedido do usuário: o relógio do Lirilì fica bem acima e a cabeça não aparecia)
	-- GlorboFruttodrillo também (14/11/2026: crocodilo comprido, a cabeça fica baixa e na frente)
	TimelineHeadBone = { LiriliLarila = true, GlorboFruttodrillo = true } :: { [string]: boolean },
	-- Som no golpe da habilidade (16/11/2026, pedido do usuário): espécie → som tocado quando o golpe COM a passiva
	-- acerta (Glorbo: a mordida que agarra). Só na tela da luta (Torre, Chefão, Duelo)
	PassiveHitSounds = {
		GlorboFruttodrillo = { Id = "rbxassetid://115878657073501", Volume = 0.45 }, -- era 0.9 (20/11/2026, -50%)
	} :: { [string]: { Id: string, Volume: number } },
}

return BattleFxConfig
]=]
SOURCES["src/shared/Config/BlockAnimConfig.luau"] = [=[
--[[
	BlockAnimConfig — como cada modelo do Blockbench usa as suas animações no jogo. Esta tabela é a dos modelos
	feitos à mão; os gerados por tools/modelgen ficam em Config/BlockAnimGenerated.

	  Attacks  → golpes na luta: Name = animação, Hit = segundo em que acerta. O normal usa o 1º;
	             a habilidade com Fx usa um por pancada.
	  Reach    → distância (studs) do alvo em que ele para para bater
	  Showcase → animação de parado na vitrine
	  Brawl    → animação de golpe na briga do Coliseu (padrão: a do 1º Attacks)
	  WalkSequence → no lugar do walk/run: estas animações em fila ("hold" no fim), uma depois da outra enquanto anda;
	                 parou = a que está tocando vai até o fim e fica no último quadro (Chimpanzini, 14/11/2026)
	  RunSequence → com WalkSequence: a fila de correr (mesmo tamanho), usada a partir da velocidade de correr; a
	                 próxima da fila sai dela na mesma posição. Desacelerando, a próxima da fila não começa
	  IdleExtras → animações de parado que tocam de vez em quando por cima do idle: Names, Every = { mín, máx } segundos
	  Layers   → animações em loop que tocam SEMPRE por cima de todas (idle/walk/run/golpe): Names; PausedBy = animações
	             tocadas pelo Play que tiram a camada enquanto tocam (some e volta junto com elas)
	  Charge   → habilidade que carrega na luta: Bones ficam escondidos na luta e aparecem quando carrega (com
	             Animation); somem no ataque que gasta a carga (BlockAnimController:SetCharged; eventos Charge/Discharge)
	  Parry    → esquivou e vai revidar (luta por turnos): toca Animation no lugar do golpe; Block = segundo da animação em
	             que o golpe de quem bateu chega (a esquiva), Hit = segundo em que o revide acerta. Quem bateu fica parado
	             (Freeze) de Block até Hit (Cappuccino, 14/11/2026). Também vale para o revide SEM esquiva (Blueberrini,
	             18/11/2026: apanhou, Block 0 = a animação começa na pancada, quem bateu congela até o revide)
	  IdleWhileWalking → o idle toca sempre, até andando; o "walk" só soma por cima enquanto anda (sem "run")
	  IdleAlways → o idle é a base SEMPRE, na força toda, e nunca volta ao começo: o tempo dele corre direto, sem dar a
	             volta no fim (contas do arquivo que não fecham no tamanho da animação não pulam). Walk, run, golpes e
	             habilidades (até as "exclusivas") somam por cima dele (Cappuccino, 14/11/2026, pedido do usuário)
	  HorizontalSpeed → walk/run só pela velocidade no chão: subir e descer (pulo, queda) não liga o andar (Cappuccino)
]]

local Generated = require(script.Parent.BlockAnimGenerated) :: { [string]: any }

export type Attack = { Name: string, Hit: number, End: number? } -- End: quando o golpe termina (padrão: fim da animação)
export type Entry = {
	Attacks: { Attack }?,
	Reach: number?,
	Showcase: string?,
	Brawl: string?,
	IdleExtras: { Names: { string }, Every: { number } }?,
	WalkSequence: { string }?,
	RunSequence: { string }?,
	Charge: { Animation: string?, Bones: { string } }?,
	Layers: { Names: { string }, PausedBy: { string }? }?,
	Parry: { Animation: string, Block: number, Hit: number }?,
	IdleWhileWalking: boolean?,
	IdleAlways: boolean?,
	HorizontalSpeed: boolean?,
	NoRunToWalk: boolean?, -- do run só sai para o idle (parando), nunca para o walk
}

local SPECIES: { [string]: Entry } = {
	-- Modelo do usuário, sem animação "attack": golpe normal com o "interact" (o bote para a frente, no auge em 0,2 s).
	-- Reach 5: o nariz vai 3,6 studs à frente do centro dele. O Bombardeio (Fx "Bombs") e a briga usam o "power".
	BombardiroCrocodilo = { Attacks = { { Name = "interact", Hit = 0.2 } }, Reach = 5, Brawl = "power" },
	-- Modelo do usuário (05/11/2026): sem animação "attack"; golpe normal com o "interact" (bote com a cabeça).
	-- A habilidade (Fx "TireRoll") usa "power_in" e o osso "Tire" girando: ver BattleController/BrawlController.
	BonecaAmbalabu = { Attacks = { { Name = "interact", Hit = 0.18 } }, Reach = 3.6 },
	-- Modelo do usuário (13/11/2026): sem "attack"; golpe com o "interact" (braço para a frente, no auge em 0,15 s).
	-- O "idle_2" toca de vez em quando parada. Pirueta (HurtCharge): na luta a xícara cheia ("cafeCheio") fica
	-- escondida; quando carrega toca o "parry" e ela aparece; some no ataque que gasta a carga.
	BallerinaCappuccina = {
		Attacks = { { Name = "interact", Hit = 0.15 } },
		Reach = 4,
		IdleExtras = { Names = { "idle_2" }, Every = { 6, 14 } },
		Charge = { Animation = "parry", Bones = { "cafeCheio" } },
	},
	-- Modelo do usuário (14/11/2026; saiu do tools/modelgen): golpe com o "attack" (a tromba chicoteia, no alto em
	-- 0,3 s). O relógio flutua sempre ("clock_idle" por cima de tudo), menos no Za Warudo (Fx "TimeStop"), que toca o
	-- "za_warudo" (BattleFxConfig.TimeStop.Animation) somado ao idle, que nunca para
	LiriliLarila = {
		Attacks = { { Name = "attack", Hit = 0.3 } },
		Reach = 4.4,
		Layers = { Names = { "clock_idle" }, PausedBy = { "za_warudo" } },
	},
	-- Modelo do usuário (14/11/2026; saiu do tools/modelgen): golpe com o "attack" (a katana estica em 0,3 s). Esquivou
	-- e revida (Golpe Ninja): "parry", a esquiva em 0,2 s e o revide em 0,45 s (quem bateu fica 0,25 s parado). "walk"
	-- e "run" feitos por nós no arquivo de animação da cópia (assets/models/CappuccinoAssassino): pés virados para a
	-- frente como na referência do usuário; correndo, inclinado com os braços para trás
	-- 14/11/2026 (pedido do usuário): o idle fica sempre ligado por baixo e o resto soma nele (IdleAlways)
	CappuccinoAssassino = {
		Attacks = { { Name = "attack", Hit = 0.3 } },
		Reach = 4.2,
		Parry = { Animation = "parry", Block = 0.2, Hit = 0.45 },
		IdleAlways = true,
		HorizontalSpeed = true, -- 14/11/2026 (pedido do usuário): velocidade vertical não liga walk nem run
		NoRunToWalk = true, -- 17/11/2026 (pedido do usuário): do run nunca volta para o walk, só para o idle ao parar
	},
	-- Modelo do usuário (14/11/2026; saiu do tools/modelgen): golpe com o "attack" (a boca fecha e ele dá o bote em
	-- 0,3 s); "idle_2" (olha para os lados) de vez em quando. "bite", "attack_grab", "grab_backwards_walk", "crouch" e
	-- "interact" do arquivo ainda sem uso
	GlorboFruttodrillo = {
		Attacks = { { Name = "attack", Hit = 0.3 } },
		Reach = 4.4,
		IdleExtras = { Names = { "idle_2" }, Every = { 6, 14 } },
	},
	-- Modelo do usuário (18/11/2026; saiu do tools/modelgen): ataque básico com o "attack" (a cabeça desce em 0,25 s);
	-- idle sempre ligado por baixo. Guarda do 1º golpe (uma vez por luta): apanhou → "spell" na hora, no lugar, como o
	-- parry do Cappuccino (Parry com Block 0), e o revide acerta em 0,25 s
	BlueberriniOctopussini = {
		Attacks = { { Name = "attack", Hit = 0.25 } },
		Reach = 3.8,
		IdleAlways = true,
		Parry = { Animation = "spell", Block = 0, Hit = 0.25 },
	},
	-- Modelo do usuário (19/11/2026): "attack" = cabeçada com o corpo todo (feita por nós, pancada em 0,35 s). A Casca de
	-- Coco toca o "power" (entra no coco) e fica no "power_idle" enquanto dura (BattleFxConfig.CocoShell)
	BurbaloniLuliloli = { Attacks = { { Name = "attack", Hit = 0.35 } }, Reach = 4.4 },
	BrrBrrPatapim = { Attacks = { { Name = "attack", Hit = 0.36 } }, Reach = 3.8, Showcase = "tap" },
	-- Modelo do usuário (13/11/2026): golpe com o "attack" (cabeçada, a cabeça desce em 0,1–0,15 s). O Pulo na Cabeça
	-- (Fx "HeadJump") toca o "power" a cada pulo (BattleFxConfig.HeadJump.Animation)
	ChimpanziniBananini = {
		Attacks = { { Name = "attack", Hit = 0.12 } },
		Reach = 3.6,
		-- 14/11/2026 (pedido do usuário): andar = dois pulos em fila; o "run" do arquivo não é usado
		WalkSequence = { "walk_one", "walk_two" },
		-- Correndo: run_one/run_two do arquivo do usuário (14/11/2026; antes eram os de andar × 1,4)
		RunSequence = { "run_one", "run_two" },
	},
	FrigoCamelo = {
		Attacks = { { Name = "attack", Hit = 0.15, End = 0.6 } },
		Reach = 4,
	},
	TungTungTungSahur = {
		Attacks = {
			{ Name = "attack", Hit = 0.25 },
			{ Name = "attack2", Hit = 0.3 },
			{ Name = "attack3", Hit = 0.3 },
		},
		Reach = 3.5,
		Showcase = "aura",
	},
}

return {
	get = function(speciesId: string): Entry?
		return SPECIES[speciesId] or Generated[speciesId]
	end,
}
]=]
SOURCES["src/shared/Config/BlockAnimGenerated.luau"] = [=[
-- Gerado por tools/modelgen/build.py (nao editar a mao): golpes, alcance e vitrine dos modelos gerados.
-- O formato e o de Config/BlockAnimConfig, que junta esta tabela com a dos modelos feitos a mao.
return {
	BallerinoLololo = { Attacks = { { Name = "attack", Hit = 0.32 } }, Reach = 3.8, Showcase = "curl" },
	BananitaDolphinita = { Attacks = { { Name = "attack", Hit = 0.34 } }, Reach = 3.8, Showcase = "hop" },
	BobriniCococosini = { Attacks = { { Name = "attack", Hit = 0.3 } }, Reach = 4.4 },
	BobritoBandito = { Attacks = { { Name = "attack", Hit = 0.24 } }, Reach = 3.6, Showcase = "guard" },
	BombombiniGusini = { Attacks = { { Name = "attack", Hit = 0.3 } }, Reach = 4.6 },
	BrrEsTehPatipum = { Attacks = { { Name = "attack", Hit = 0.36 } }, Reach = 3.6 },
	BrriBrriBicusDicusBombicus = { Attacks = { { Name = "attack", Hit = 0.24 } }, Reach = 3.8, Showcase = "salute" },
	BurbaloniLuliloli = { Attacks = { { Name = "attack", Hit = 0.3 } }, Reach = 4.4 },
	CocofantoElefanto = { Attacks = { { Name = "attack", Hit = 0.26 } }, Reach = 4.2, Showcase = "trumpet" },
	EspressonaSignora = { Attacks = { { Name = "attack", Hit = 0.22 } }, Reach = 3.2, Showcase = "elegant" },
	GangsterFootera = { Attacks = { { Name = "attack", Hit = 0.26 } }, Reach = 3.4, Showcase = "swag" },
	Garamararamararaman = { Attacks = { { Name = "attack", Hit = 0.26 } }, Reach = 3.8 },
	GiraffaCeleste = { Attacks = { { Name = "attack", Hit = 0.32 } }, Reach = 4.4 },
	GraipussiMedussi = { Attacks = { { Name = "attack", Hit = 0.3 } }, Reach = 3.8, Showcase = "float" },
	IlCactoHipopotamo = { Attacks = { { Name = "attack", Hit = 0.3 } }, Reach = 4.2 },
	LaVacaSaturnoSaturnita = { Attacks = { { Name = "attack", Hit = 0.36 } }, Reach = 4.2, Showcase = "orbit" },
	OdinDinDinDun = { Attacks = { { Name = "attack", Hit = 0.24 } }, Reach = 4, Showcase = "flex" },
	OrangutiniAnanassini = { Attacks = { { Name = "attack", Hit = 0.32 } }, Reach = 3.6, Showcase = "chest" },
	OrcaleroOrcala = { Attacks = { { Name = "attack", Hit = 0.26 } }, Reach = 4.4, Showcase = "dance" },
	Pakrahmatmamat = { Attacks = { { Name = "attack", Hit = 0.3 } }, Reach = 4.8 },
	PenguinoCocosino = { Attacks = { { Name = "attack", Hit = 0.26 } }, Reach = 3.8, Showcase = "wobble" },
	PotHotspot = { Attacks = { { Name = "attack", Hit = 0.24 } }, Reach = 3.4 },
	RhinoToasterino = { Attacks = { { Name = "attack", Hit = 0.3 } }, Reach = 4.6, Showcase = "toast" },
	SpioniroGolubiro = { Attacks = { { Name = "attack", Hit = 0.2 } }, Reach = 3.4, Showcase = "spy" },
	TaTaTaSahur = { Attacks = { { Name = "attack", Hit = 0.26 } }, Reach = 4.2, Showcase = "whistle" },
	TracotucotuluDelapeladustuz = { Attacks = { { Name = "attack", Hit = 0.26 } }, Reach = 4.4 },
	TralaleroTralala = { Attacks = { { Name = "attack", Hit = 0.26 } }, Reach = 4.6, Showcase = "dance" },
	TrippiTroppi = { Attacks = { { Name = "attack", Hit = 0.3 } }, Reach = 4.6, Showcase = "confused" },
	TrulimeroTrulichina = { Attacks = { { Name = "attack", Hit = 0.3 } }, Reach = 4.8 },
	ZibraZubraZibralini = { Attacks = { { Name = "attack", Hit = 0.34 } }, Reach = 4.2 },
}
]=]
SOURCES["src/shared/Config/BrainrotConfig.luau"] = [=[
--[[
	BrainrotConfig — regras gerais dos brainrots (talentos, estrelas, nível, inventário, venda).
	Decisões em docs/game-design.md.
]]

local BrainrotConfig = {
	-- Talentos (05/11/2026, pedido do usuário): cada stat (Vida, Ataque, Velocidade) tem um talento em %.
	-- Ao chocar, o MÁXIMO de cada um é sorteado entre TalentMaxMin e TalentMaxMax e o ATUAL entre 0 e
	-- TalentStartShare × máximo. Stat = base × (1 + atual / 100): base 300 com talento 40 = 300 + 40% = 420.
	-- O atual sobe até o máximo treinando (mecânica futura).
	TalentMaxMin = 20,
	TalentMaxMax = 100,
	TalentStartShare = 0.5,
	-- Sorteio do máximo em faixas (pedido do usuário, 06/11/2026), menos nos ovos com MinTalent (Cósmico: de 60 a 100,
	-- sorteio igual). Primeiro sorteia a faixa pela Chance; dentro dela, todo número tem a mesma chance, menos com Decay:
	-- aí cada ponto vale e^(−Decay) do anterior (o 100 fica com 0,5%).
	-- 12/11/2026 (pedido do usuário): os 3 stats com teto 65+ num brainrot = 6% → cada stat 65+ = 39,1% (0,391³ ≈ 6%);
	-- as duas faixas de baixo dividem o resto na mesma proporção de antes (eram 25/50/25%)
	--   20–39: 20,3%   40–64: 40,6%   65–100: 39,1% (caindo aos poucos: 65 ≈ 1,45%, 100 ≈ 0,78%)
	TalentBands = {
		{ From = 20, To = 39, Chance = 0.203 },
		{ From = 40, To = 64, Chance = 0.406 },
		{ From = 65, To = 100, Chance = 0.391, Decay = 0.0178 },
	},
	-- Teto de qualquer talento, em % (para conferir dados que chegam de fora)
	MaxTalent = 100,

	-- Estrelas (Máquina de Fusão): bônus acumulado nos stats em cada estrela
	-- Pedido do usuário (05/11/2026): máximo 3 estrelas; a 1ª e a 2ª dão +25% cada e a última dá +50%
	StarBonus = { 0.25, 0.5, 1 },
	MaxStars = 3,
	-- Selo de estrela no canto do cartão da mochila (pixel art do usuário em assets/ui/stars, ampliada 16x)
	StarIcons = {
		"rbxassetid://83394221768582", -- 1 estrela
		"rbxassetid://109469035514528", -- 2 estrelas
		"rbxassetid://112513791614149", -- 3 estrelas
	},
	-- Tamanho em pixels de cada desenho original (assets/ui/stars/original): o selo usa o mesmo tamanho de
	-- pixel nos três e um número inteiro de pixels da tela por pixel do desenho (senão aparece "mixel")
	StarIconSizes = { { 14, 13 }, { 21, 13 }, { 21, 19 } },
	-- Fusão de estrelas (pedido do usuário, 05/11/2026): o alvo + StarFuseCopies cópias da mesma espécie
	-- com as MESMAS estrelas dele → o alvo ganha 1 estrela e fica com os talentos dele
	StarFuseCopies = 2,

	-- Diamantes (pedido do usuário, 05/11/2026; regras em Shared/Brainrot/Diamonds): a base de cada raridade
	-- 12/11/2026 (pedido do usuário): o dobro (eram 10/20/40/80/150/200/350) e SEM sorteio: todo brainrot da raridade
	-- vem com este valor × o tamanho (SizeConfig.statMultiplier: até 3x com 400%). A curva continua só para as moedas/s
	-- 13/11/2026 (pedido do usuário): 30/60/150/300/500/800/1600 (eram 20/40/80/160/300/400/700; migração 11 ajusta os salvos)
	DiamondMin = {
		Common = 30,
		Uncommon = 60,
		Rare = 150,
		Epic = 300,
		Legendary = 500,
		Mythic = 800,
		Secret = 1600,
	},
	DiamondCurve = { K = 0.712, P = 0.913 },

	-- Moedas por segundo na vitrine (pedido do usuário, 07/11/2026; regras em Shared/Brainrot/Gold): o mínimo de
	-- cada raridade; o máximo é GoldMaxMultiplier × o mínimo (mesma curva dos diamantes). Nunca acaba.
	-- 12/11/2026 (pedido do usuário): tudo pela metade, porque o tamanho agora soma até +200% (Gold.perSecond); depois
	-- (mesmo dia) +50% e arredondado para cima, sem número quebrado (eram 0,5 / 1,5 / 3 / 7,5 / 15 / 35 / 125)
	GoldMin = {
		Common = 1,
		Uncommon = 3,
		Rare = 5,
		Epic = 12,
		Legendary = 23,
		Mythic = 53,
		Secret = 188, -- Prismático
	},
	-- Máximo = 4x o mínimo (12/11/2026, pedido do usuário; era 10x). O sorteio é a mesma curva dos diamantes até
	-- GoldCurveTop, comprimida para 1x–GoldMaxMultiplier (o 4x continua tão raro quanto era o 10x). Sai um número inteiro
	GoldMaxMultiplier = 4,
	GoldCurveTop = 10,

	-- Cada nível acima do 1 soma esta fração da base nos três stats (pedido do usuário, 05/11/2026; o Growth
	-- de SpeciesConfig ficou sem uso)
	LevelStatBonus = 0.02,

	-- Nível máximo: 200 (pedido do usuário, 03/11/2026; era 30). A Torre foi calibrada até o nível 30.
	MaxLevel = 200,
	-- Aura (XP) para passar do nível N para o N+1 (06/11/2026, pedido do usuário):
	--   floor(XpBase + XpScale × (N − 1)^XpExponent)
	-- Ajustada com a Aura da Torre (TowerConfig.auraFor): um brainrot que não cai chega a ~nível 60 no andar 100 e
	-- ~nível 110 no andar 200 (andar 10 ≈ nível 9, 50 ≈ 33, 150 ≈ 85, 300 ≈ 157, 400 = 200). O 1 → 2 custa 20.
	-- Ex.: 10 → 11 = 2.314; 50 → 51 = 126.259; 100 → 101 = 666.109; 199 → 200 = 3.431.201. Do 1 ao 200: ~204M.
	XpBase = 20,
	XpScale = 12.706259,
	XpExponent = 2.3649185,
	-- Renda exposta: +2% por nível acima do 1
	IncomePerLevel = 0.02,
	-- Venda: +10% por nível acima do 1
	SellPerLevel = 0.1,

	-- Espaço no inventário de um jogador novo
	StartingCapacity = 150,

	-- Time: quantos brainrots seguem o jogador (e lutam, na ordem da fila)
	-- O Poder de cada um é √(Vida × Ataque × Velocidade) (BrainrotStats.power); o do time é a soma.
	TeamSize = 3,
	-- Presets do time (abas 1/2/3 do lado da mochila; 15/11/2026, pedido do usuário)
	TeamPresets = 3,
	TeamPresetNameMax = 20, -- letras do nome de um preset (lápis da mochila; 16/11/2026)
}

return BrainrotConfig
]=]
SOURCES["src/shared/Config/BrawlConfig.luau"] = [=[
--[[
	BrawlConfig — a briga dos brainrots no Coliseu (etapa 9; design em docs/design-etapa-9-arena.md, A.3).

	Dentro do Coliseu, o time de cada jogador briga sozinho com os times dos outros: cada brainrot vai
	atrás do brainrot inimigo mais perto em QUALQUER lugar do Coliseu; sem nenhum para bater, vai atrás
	do jogador inimigo que está lá dentro e o empurra (pedido do usuário, 03/11/2026; no design eram
	9 studs de alcance e coleira de 14 studs do dono, e só brigavam com os donos colados).
	Não usa a Vida de verdade: cada brainrot tem Vida de briga pelo papel, e a força vem do Poder
	comparado com o do alvo. As habilidades valem aqui (Server/Events/BrawlSkills, pedido do usuário,
	04/11/2026). O jogador nunca perde Vida: o golpe de um brainrot o manda para o próprio terreno.

	A Vida de briga fica guardada (sair e entrar no Coliseu não cura). Nocauteado fica fora até o dono
	passar ReviveOutsideSeconds FORA do Coliseu; aí volta com ReviveHp da Vida. Para encher a Vida,
	só no terreno do dono (onde fica a vitrine de Aura): de 0 a cheio em HomeHealSeconds. Brainrot
	exposto na vitrine também cura (pedido do usuário, 03/11/2026; no design, o nocaute durava 6 s e
	a Vida voltava sozinha).

	dano = Damage(papel) × F × variação × crítico,  F = limita((Poder ÷ Poder do alvo) ^ PowerExponent)
]]

local BrawlConfig = {
	-- Brainrots batem nos brainrots e empurram os jogadores dos outros? (06/11/2026: desligado, pedido do usuário;
	-- 10/11/2026: as habilidades de área também não acham mais os brainrots dos outros)
	PvP = false,
	Tick = 0.1, -- s (10 vezes por segundo no servidor)
	HitRange = 4,
	UnitSpeed = 30, -- studs/s (o jogador anda a 24)
	FloorApothem = 40.5, -- o chão útil do Coliseu (13/11/2026: era 27; Coliseu 50% maior)

	-- Vida de briga × dano por segundo ≈ 1.300 nos quatro papéis: nenhum é melhor com o mesmo Poder
	Roles = {
		Tank = { Hp = 180, Damage = 9, Interval = 1.25, Push = 1.3 },
		Fighter = { Hp = 130, Damage = 10, Interval = 1, Push = 1 },
		Attacker = { Hp = 110, Damage = 13, Interval = 1.1, Push = 1.1 },
		Speedy = { Hp = 117, Damage = 8, Interval = 0.72, Push = 0.75 },
	},

	-- 0.33 com o Poder √(Vida × Ataque × Vel) (era 0.5 com a fórmula antiga)
	PowerExponent = 0.33,
	PowerMin = 0.4,
	PowerMax = 2.5,
	Variation = { 0.9, 1.1 },
	CritChance = 0.1, -- igual à luta: 10% de crítico base
	CritMultiplier = 1.5,

	-- Sem brainrot inimigo para bater: o golpe no jogador inimigo o manda para o próprio terreno
	PlayerHitCooldown = 1.2,
	PlayerHomeFront = 6, -- studs da entrada do terreno até onde ele aparece
	PlayerHomeHeight = 5,

	-- Habilidades na briga (Server/Events/BrawlSkills)
	Skills = {
		TurnSeconds = 1.25, -- "1 turno" das passivas em segundos
		-- Habilidades "de início da luta" (escudo, Arrancada, NUKE...) valem ao chegar e de novo a cada isto (13/11/2026)
		RestartSeconds = 10,
		ComboGap = 0.3, -- entre os golpes de uma sequência (as 3 pancadas do Tung)
		AreaRadius = 12, -- alcance dos golpes em todos os inimigos (Bombardeio)
		StunImmuneSeconds = 1.5, -- depois de um atordoamento, não pode levar outro (ninguém fica preso)
		MinStatFactor = 0.4, -- enfraquecimentos não baixam Ataque nem Velocidade além disto
	},

	PushStuds = 3, -- empurrão no brainrot atingido (× F, limitado; dobra no crítico)
	PushMin = 0.7,
	PushMax = 1.5,
	PushTime = 0.2,

	ReviveOutsideSeconds = 10, -- nocauteado volta quando o dono fica isto FORA do Coliseu...
	ReviveHp = 0.25, -- ...com esta fração da Vida de briga
	HomeHealSeconds = 30, -- no terreno do dono (ou exposto na vitrine), de 0 a Vida cheia
	HomeMargin = 2, -- studs de folga em volta do terreno
	ArrivalShield = 0, -- imunidade ao entrar no Coliseu (0 = sem bolha, pedido do usuário)
	ArrivalAfterOutside = 30, -- ...se estava fora havia pelo menos isto

	-- Prêmio de nocaute: 2 s de R (mínimo 10) para quem deu o golpe final, se a vítima não for fraca
	-- demais (Poder do time ≥ 50% do seu) e o mesmo par não passou de 3 prêmios em 5 min
	KoRewardSeconds = 2,
	KoRewardMin = 10,
	KoMinPowerRatio = 0.5,
	KoPairLimit = 3,
	KoPairWindow = 300,
}

return BrawlConfig
]=]
SOURCES["src/shared/Config/CombatConfig.luau"] = [=[
--[[
	CombatConfig — regras da luta por turnos (Torre, duelos e Arena usam o mesmo motor).
	Regras completas em docs/design-etapas-6-8.md, parte 3.

	Linha do tempo: cada brainrot age a cada ActionTime / Velocidade (tempo da luta, não segundos),
	então quem tem o dobro de Velocidade age duas vezes mais. O servidor calcula a luta inteira e
	manda o "roteiro" (lista de eventos); o cliente só anima, com os tempos de EventTime.
]]

local CombatConfig = {
	-- Intervalo entre dois turnos de um brainrot = ActionTime / Velocidade
	ActionTime = 100,
	-- Morte súbita nas lutas de 2 times (Torre, Chefão, PvP; 14/11/2026, pedido do usuário: no lugar de acabar o tempo e
	-- vencer quem tinha mais Vida). No turno StartTurn (somando os dois lados) o dano de todos sobe Bonus (+300%), e mais
	-- Bonus a cada Every turnos depois (30 = +300%, 35 = +600%...). Igual à da Arena (ArenaBattleConfig.Overtime)
	SuddenDeath = { StartTurn = 30, Every = 5, Bonus = 3 },
	-- Só segurança (cura/escudo sem fim): chegou nele, vence quem tem mais % de Vida. Com a morte súbita não chega
	MaxTurns = 200, -- era 60 (o limite de tempo da luta até 14/11/2026)
	-- Dano do golpe: sorteado entre DamageMin e DamageMax vezes o Ataque (08/11/2026, pedido do usuário: 100 de Ataque
	-- = 80 a 100 de dano), antes de crítico, habilidades e redução. A Vida das espécies subiu 8x para compensar.
	DamageMin = 0.8,
	DamageMax = 1,
	-- Crítico que todo brainrot tem (a passiva Crit sorteia à parte; vale o maior multiplicador)
	BaseCritChance = 0.1, -- todo brainrot tem 10% de crítico base (pedido do usuário, 05/11/2026)
	BaseCritMultiplier = 1.5,
	-- Esquiva e Espinhos (stats novos, pedido do usuário, 07/11/2026; aparecem no "i" da mochila): o que todo brainrot
	-- tem, somado ao da passiva e ao da árvore de skills. Esquiva = chance de não levar o golpe; Espinhos = fração do
	-- dano recebido que volta em quem bateu.
	BaseDodgeChance = 0,
	BaseThornsPercent = 0,
	-- Enfraquecimentos nunca deixam Ataque e Velocidade abaixo dessa fração do original
	MinStatFactor = 0.5,
	-- Diferença de tempo que conta como empate na linha do tempo
	TieEpsilon = 0.000001,

	-- Za Warudo na briga do Coliseu (13/11/2026): o 1º golpe Delay s depois do "ZA WARUDO!" e os outros a cada Gap s
	TimeStopHits = { Delay = 0.5, Gap = 0.25 },

	-- Quanto tempo (s, na velocidade 1x) a tela gasta em cada evento do roteiro.
	-- Eventos que não estão aqui aparecem junto do anterior (não gastam tempo).
	EventTime = {
		Start = 1, -- entrada dos times
		Attack = 0.6,
		Extra = 0.45,
		-- Za Warudo (13/11/2026, pedido do usuário): o tempo para; 0,5 s depois os alvos levam um golpe a cada 0,25 s
		-- (4 golpes) e acaba: 1,5 s no total. Briga do Coliseu: CombatConfig.TimeStopHits; Arena: ArenaBattleConfig.TimeStop
		TimeStop = 0.5, -- "ZA WARUDO!": a tela fica cinza (era 1,1)
		TimeStopHit = 0.25, -- cada golpe com o tempo parado (todos os alvos do golpe juntos)
		TimeResume = 0, -- o tempo volta (era 0,5; o cinza some sozinho)
		ShieldBreak = 0.35,
		Blow = 0.2, -- cada golpe a mais do padrão (Tung)
		Counter = 0.35,
		Skip = 0.45, -- perdeu o turno (atordoado)
		-- Casca de Coco (Burbaloni, 19/11/2026): entra no coco (animação "power"), fica parado, sai
		Shell = 0.8,
		ShellHold = 0.45,
		ShellOut = 0.3,
		Burn = 0.3,
		Heal = 0.25,
		Buff = 0.15,
		Reflect = 0.2,
		Debuff = 0.3, -- lentidão no início (Gravidade)
		Death = 0.5,
		Overtime = 1.2, -- "🔥 MORTE SÚBITA! DANO +300%" no meio da tela (14/11/2026)
		Revive = 0.9,
		Rush = 0.4, -- Sem Sinal do Pot Hotspot: "TURNO EXTRA!"
		Charge = 0.15, -- Pirueta da Ballerina: "PRÓXIMO 2x!"
		-- Mordida do Glorbo (13/11/2026): arrasta o alvo na boca até o lugar dele e os aliados se viram. Na tela o tempo
		-- é o do próprio handler (BattleController); aqui é só a conta da duração da luta no servidor
		Grab = 1.4,
		Release = 1.8, -- ...espera as habilidades acabarem e o alvo volta andando para o lugar
	},
	-- Banner de vitória/derrota no fim (fora da conta da duração)
	ResultBannerTime = 2,

	-- Anti-pressa: o próximo "Lutar" do mesmo jogador só vale depois de duração × este fator
	-- (0.5 = a duração da luta no 2x)
	RetryCooldownFactor = 0.5,
	-- Quando o cliente fecha a tela da luta (acabou ou pulou), a próxima pode começar depois disto (s)
	SkipRetry = 0.3,
	-- Subida da Torre com a luta pulada (Pular ou Auto): pausa antes de pedir o próximo andar (s), um pouco maior que o
	-- SkipRetry (o servidor recusaria antes). O pedido sai com o "VITÓRIA!" ainda na tela e o próximo andar começa
	-- quando ele some (14/11/2026, pedido do usuário)
	AutoSkipGap = 0.35,
	-- Sem aviso do cliente, a luta é dada como fechada depois de duração + esta folga (s)
	ViewTimeoutSlack = 15,

	-- Nenhum enfraquecimento dura para sempre (12/11/2026, pedido do usuário): dura pelo menos isto (o motor e a briga
	-- trocam Turns ausente ou 0 por este valor)
	MinDebuffTurns = 1,

	-- Habilidades crescem com as estrelas (13/11/2026, pedido do usuário; Shared/Brainrot/PassivePower): +50% por
	-- estrela, somando (3★ = 2,5x) nas chances, no dano e em espinhos/redução/roubo de vida/escudo/cura
	PassiveStarBonus = 0.5,
	PassiveMaxChance = 1, -- chance nunca passa de 100%
	PassiveMaxReduction = 0.9, -- redução de dano e enfraquecimento crescidos param em 90%
	-- Teto UNIVERSAL da redução de dano (15/11/2026, pedido do usuário): somando tudo (passiva, árvore, artefato, Fúria
	-- sem fim do Chefão), um golpe nunca perde mais que 90% (BattleEngine.rollDamage e BrawlSkills)
	MaxDamageReduction = 0.9,
	-- Dano verdadeiro (17/11/2026, pedido do usuário): atravessa redução e escudo; número rosa choque
	TrueDamageColor = Color3.fromRGB(230, 30, 140),

	-- Lutas em tempo real (Arena e briga do Coliseu: Patapim, Piñata...; 13/11/2026, pedido do usuário): ataques por
	-- segundo em linha reta pela Velocidade ATUAL (lentidão e SpdUp mudam a Velocidade), pelos dois pontos:
	-- ataques/s = (1500 + Velocidade) / 2000 → 0 = 0,75/s, 500 = 1/s, 1000 = 1,25/s, 2000 = 1,75/s, 2500 = 2/s
	-- (20/11/2026, pedido do usuário: +0,25/s a cada 500 de Velocidade, de volta; no mesmo dia tinha ido a +0,20;
	-- antes +0,33). A luta por turnos (Torre) não usa isto.
	RealtimeAttack = {
		Low = { Spd = 500, PerSecond = 1 },
		High = { Spd = 2500, PerSecond = 2 },
		MinPerSecond = 0.25, -- piso de segurança
	},
}

-- Segundos entre dois ataques numa luta em tempo real, pela Velocidade atual (CombatConfig.RealtimeAttack)
function CombatConfig.attackInterval(speed: number): number
	local config = CombatConfig.RealtimeAttack
	local slope = (config.High.PerSecond - config.Low.PerSecond) / (config.High.Spd - config.Low.Spd)
	local perSecond = config.Low.PerSecond + (speed - config.Low.Spd) * slope
	return 1 / math.max(config.MinPerSecond, perSecond)
end

return CombatConfig
]=]
SOURCES["src/shared/Config/EventConfig.luau"] = [=[
--[[
	EventConfig — os eventos do Coliseu (etapa 9; design em docs/design-etapa-9-arena.md, parte A).

	"Entrou, já está jogando": sem inscrição nem fila. Participa quem está DENTRO do Coliseu.
	Agenda GLOBAL desde 10/11/2026 (pedido do usuário; Shared/Events/EventSchedule): ciclo de 12 min (era 20 até 12/11/2026), igual em todos os
	servidores; Coliseu no minuto 3, evento da ilha no minuto 9, a Máquina de Vendas troca nos minutos 0 e 6. O
	evento de cada ciclo sai do peso em Rotation/IslandRotation, nunca um dos 2 anteriores da mesma lista.

	Prêmios em "segundos de R": R = renda da vitrine por segundo + JunkIncomeEstimate × multiplicador da
	Trituradora. Assim o prêmio vale o mesmo no minuto 10 e na hora 20 (passa pelo multiplicador de moedas).
]]

local EventConfig = {
	-- Agenda global (Shared/Events/EventSchedule). Epoch = 10/11/2026 00:00 UTC (múltiplo do ciclo e das rodadas de
	-- 6 min da Máquina de Vendas, para os minutos 0 e 6 do ciclo serem as trocas dela)
	Schedule = {
		Epoch = 1794268800,
		-- Uma coisa a cada 3 min (12/11/2026, pedido do usuário; era de 5 em 5): ciclo de 12 min, loja/ovos do campo nos
		-- minutos 0 e 6 (ShopConfig.RotationSeconds), Coliseu no 3, ilha no 9
		Cycle = 12 * 60,
		ColiseumAt = 3 * 60, -- começo do evento do Coliseu, contado do começo do ciclo
		IslandAt = 9 * 60, -- começo do evento da ilha (Bombardiro: a hora em que ele aparece no céu)
		NoRepeat = 2, -- o evento não pode ser nenhum destes últimos da mesma lista
		Seed = 20261110,
	},
	-- Peso de cada evento do Coliseu no sorteio do ciclo (o Ovo Cósmico sai o dobro)
	Rotation = { CosmicEgg = 2, Pinata = 1, KingOfTheRing = 1, PatapimBoss = 1, Ufo = 1, ArenaBattle = 1 },
	-- Eventos da ilha (fora do Coliseu): "Airdrop" = Bombardiro (AirdropService); os outros rodam pelo EventService
	-- (14/11/2026: entrou a Caça aos Ovos; 15/11/2026: o Balão)
	IslandRotation = { Airdrop = 1, GoldenFrigo = 1, EggHunt = 1, Balloon = 1, Volcano = 1 },

	AnnounceBefore = 60, -- faixa no topo de todas as telas
	ToastBefore = 30, -- aviso para quem está fora do Coliseu
	CountdownBefore = 10, -- contagem 10…1 e param de cair tralhas
	-- Eventos da ilha (Bombardiro, Frigo Dourado; 12/11/2026, pedido do usuário): faltando tanto para começar, os
	-- brainrots que seguem os jogadores somem para todo mundo e só voltam quando o evento acaba. Atributo
	-- "IslandTeamsHidden" no Workspace (AirdropService/EventService) → Client/FollowController
	IslandHideTeamsBefore = 10,
	CountdownRadius = 150, -- contagem grande na tela de quem está até aqui do centro (13/11/2026: era 120; Coliseu 50% maior)
	ResultsTime = 8, -- quanto tempo o telão mostra o vencedor

	-- R = vitrine + isto (renda das tralhas estimada, moedas por segundo)
	JunkIncomeEstimate = 13,
	-- Quem "participou" (ganha a consolação): tempo dentro do Coliseu e passos dados durante o evento
	Participation = { MinSeconds = 30, MinStuds = 30 },
	Tick = 0.1,

	Events = {
		-- Arena (08/11/2026, pedido do usuário; Server/Events/ArenaBattle): 4 jogadores, 3 brainrots cada, cada um por si.
		-- Fases, tempos e regras da luta em Config/ArenaBattleConfig
		ArenaBattle = {
			Name = "Arena",
			Title = "ARENA",
			Icon = "⚔️",
			Goal = "Entre num círculo verde e lute!\nQuanto melhor o lugar, mais 💎 e moedas!",
			Brawl = false,
			-- 14/11/2026 (pedido do usuário): o time de quem não está lutando some dentro do Coliseu (a briga não desenha;
			-- o FollowController esconde até a porta, arenaEventHides). Os lutadores são desenhados pelo ArenaBattleController
			HideTeams = true,
			KeepWhenDrawn = true,
		},
		Pinata = {
			Name = "Piñata Absurda",
			Title = "PIÑATA ABSURDA",
			Icon = "🪅",
			Goal = "Seus brainrots batem na piñata!\nA cada 20K de dano: 💎 e moedas!", -- 14/11/2026: mais direto
			Brawl = false,
			Duration = 45, -- 16/11/2026 (pedido do usuário): era 75
			-- um marco a cada tanto de dano do servidor (soma do dano de cada golpe, 80% a 100% do Ataque); 12/11/2026
			-- (pedido do usuário): era 76.500
			GoalDamage = 20000,
			VaultShare = 0.5, -- do total do Cofre, a cada GoalDamage do PRÓPRIO jogador, pago no fim (13/11/2026: era 75%; antes 15%)
			DamageReduction = 0.3, -- 16/11/2026 (pedido do usuário): 30% a menos em todo golpe; Chamas de Goes furam
			DiamondsPerGoal = 50, -- e mais estes diamantes por marco (12/11/2026, pedido do usuário)
			HitRange = 7,
			BobSpeed = 6,
			BobHeight = 0.6,
			HudEvery = 0.25,
		},
		-- Invasão OVNI (06/11/2026, pedido do usuário; Server/Events/Ufo): nave zanzando e raio que dá talento e diamantes
		Ufo = {
			Name = "Invasão OVNI",
			Title = "INVASÃO OVNI",
			Icon = "🛸",
			Goal = "Aumenta talentos e recupera os diamantes dos brainrots equipados!", -- texto do usuário (14/11/2026)
			Brawl = false,
			-- MinPlayers saiu em 07/11/2026 (pedido do usuário): todo evento acontece com qualquer número de jogadores
			KeepWhenDrawn = true, -- sorteado, acontece mesmo se sair gente depois (pedido do usuário)
			Duration = 75,
			-- Segunda nave (13/11/2026, pedido do usuário): com ExtraShipPlayers ou mais jogadores no servidor quando começa
			ExtraShipPlayers = 5, -- (velho: desde 14/11/2026 vale o ShipsByPlayers)
			-- 14/11/2026 (pedido do usuário): naves pelo número de jogadores no SERVIDOR (do maior para o menor): 3 a partir de
			-- 7, 2 a partir de 3, senão 1. Entrou gente no meio do evento: nascem as que faltam (nunca some nenhuma)
			ShipsByPlayers = { { Players = 7, Ships = 3 }, { Players = 3, Ships = 2 } },
			MaxShips = 3,
			Height = 19, -- altura da nave acima do piso (06/11/2026: +20%; o raio cresce junto)
			Speed = 24.75, -- studs/s zanzando (06/11/2026: era 9; 13/11/2026: era 11, × 1,5 com o Coliseu; 14/11/2026: +50%, era 16,5)
			MaxDistance = 37.5, -- até onde ela vai, do centro do Coliseu (06/11/2026: era 18; 13/11/2026: era 25; o Coliseu tem 45)
			WanderTime = { 2, 2 }, -- segundos zanzando antes de parar (14/11/2026, pedido do usuário: 2 s; era 3 a 6)
			BeamTime = 5, -- segundos com o raio ligado
			BeamRadius = 5, -- raio do desenho do feixe
			BeamHitScale = 1.2, -- raio de quem ganha = BeamRadius × isto (10/11/2026: +20% só na hitbox, o visual fica igual)
			TalentPerSecond = 2, -- por segundo, num talento ATUAL sorteado de cada um dos 3 do time (até o teto)
			DiamondsPerSecond = 0.07, -- do DiamondMax de cada um dos 3 do time (06/11/2026: era 5%; 10/11/2026: 10% → 7%)
			HudEvery = 0.25,
		},
		PatapimBoss = {
			Name = "Brr Brr Patapim",
			Title = "CHEFÃO: BRR BRR PATAPIM",
			Icon = "🌳",
			Goal = "Derrote o chefão e ganhe o Ovo da Natureza!\nFuja das marcas vermelhas!",
			Brawl = false,
			-- MinPlayers saiu em 07/11/2026 (pedido do usuário): todo evento acontece com qualquer número de jogadores
			Duration = 90,
			Species = "BrrBrrPatapim",
			Scale = 2.5,
			HitRange = 8,
			ArenaRadius = 36, -- onde os círculos aleatórios caem (13/11/2026: era 24; Coliseu 50% maior)
			PlayerDamage = 40, -- Vida tirada do jogador em cada ataque (fixo; o jogador tem 100 + a árvore de skills)
			HitFraction = 0.002, -- cada ataque de brainrot tira esta fração da Vida dele (0,2%; pedido do usuário)
			-- Dano "artificial" (itens: Jakalopita, Julgamento de Eyros) tira esta fração a cada vez que sai (0,05%; 14/11/2026,
			-- pedido do usuário; antes os itens não davam nada nele)
			ArtificialFraction = 0.0005,
			EggShare = 0.1, -- fração da Vida dele que o jogador precisa ter tirado para ganhar o ovo (10%; era 5%, 16/11/2026)
			Egg = "NatureEgg",
			-- Se ele morrer, quem ganhou o ovo leva também VaultShare do limite do Cofre em moedas (12/11/2026, pedido do
			-- usuário; passa pelo multiplicador, como a Piñata)
			VaultShare = 1.5,
			-- segundos de espera depois de um ataque terminar (05/11/2026: -1 s; 07/11/2026: -0,75 s, pedidos do usuário)
			AttackGap = { 0.25, 1.75 },
			RepeatChance = 0.25, -- chance de repetir o mesmo ataque
			-- Telegraph 0,5 s mais rápido nos dois ataques (07/11/2026, pedido do usuário: 1.2 → 0.7 e 1.5 → 1)
			-- 13/11/2026 (pedido do usuário): +1 linha reta a cada PlayersPerExtraLine jogadores batendo nele (brainrots que
			-- acertaram nos últimos HitterWindow s), até MaxLines de uma vez; linhas a pelo menos MinLineAngle graus uma da outra
			-- 14/11/2026 (pedido do usuário): SEMPRE Lines linhas (3), a pelo menos MinLineAngle graus (15) uma da outra,
			-- cada uma mirando um jogador diferente (o mais perto primeiro); faltando jogador, espalhadas em volta. Sem
			-- Lines, volta a regra de 13/11 (1 + 1 a cada PlayersPerExtraLine batendo nele, até MaxLines)
			Slam = {
				Telegraph = 0.7,
				Length = 45, -- 13/11/2026 (pedido do usuário): +50% de alcance (era 30)
				Width = 15, -- 13/11/2026 (pedido do usuário): +25% de largura (era 12)
				Travel = 0.45,
				WaveHeight = 6,
				Lines = 3,
				PlayersPerExtraLine = 3,
				MaxLines = 3,
				HitterWindow = 5,
				MinLineAngle = 15, -- era 40
			},
			-- Telegraph: tempo até o círculo vermelho encher e as raízes saírem (05/11/2026: 2 → 1.5, pedido do usuário).
			-- StompAt: segundo da animação "summon" em que ele pisa; ela toca mais rápido para pisar na hora certa.
			-- RandomCircles: círculos sorteados, fora o de cada jogador (14/11/2026, pedido do usuário: era 5)
			Roots = { Telegraph = 1, StompAt = 2, RandomCircles = 7, Radius = 6, RootSeconds = 3 },
			-- Floresta (14/11/2026, pedido do usuário): o chão INTEIRO fica marcado de vermelho, enchendo do centro até a
			-- borda em Telegraph (50% mais que as Roots), menos SafeZones círculos verdes (efeito de área, como o do Cofre) de
			-- SafeRadius; cheio, espinhos sobem no chão todo e prendem (RootSeconds das Roots) e machucam quem ficou fora
			-- dos verdes. FloorRadius = até onde vai (o apótema do Coliseu); os verdes nascem a até SafeSpread do centro,
			-- a pelo menos SafeGap um do outro; SpikeSpacing = distância entre os espinhos do desenho
			Forest = {
				Telegraph = 1.62, -- 14/11/2026 (pedido do usuário): -10% (era 1,8; antes 1,5)
				-- Espinhos ficam SpikeSeconds no chão e prendem esse mesmo tempo (14/11/2026, pedido do usuário: 1,25 → 1 s)
				SpikeSeconds = 1,
				-- Enquanto carrega, a borda do Coliseu (o LED, MapConfig.Octagon.Apothem) vira parede: ninguém entra nem sai
				WallHeight = 40,
				WallThickness = 2,
				StompAt = 2,
				SafeZones = 2,
				SafeRadius = 7,
				SafeSpread = 30,
				SafeGap = 18,
				FloorRadius = 45,
				SpikeSpacing = 5,
			},
			HudEvery = 0.25,
		},
		-- Rei da Colina (refeito em 05/11/2026, pedido do usuário): um círculo no piso fica parado HoldTime s e pula
		-- bruscamente (MoveTime s) para outro lugar, por Duration s. Ganha quem ficou mais tempo dentro dele.
		-- 1º: diamantes de DiamondsMin a DiamondsMax (pelo nível do maior brainrot, 1 a 200) + VaultShare do limite
		-- do Cofre em moedas; 2º: SecondShare disso; os outros nada.
		KingOfTheRing = {
			Name = "Rei da Colina",
			Title = "REI DA COLINA",
			Icon = "👑",
			Goal = "Fique no círculo o maior tempo!\nGanha muitos 💎 e moedas!",
			Brawl = false,
			-- MinPlayers saiu em 07/11/2026 (pedido do usuário): todo evento acontece com qualquer número de jogadores
			Duration = 60,
			Radius = 9, -- raio do círculo (studs; 13/11/2026: era 6, +50% a pedido do usuário)
			-- Quantos círculos ao mesmo tempo (13/11/2026, pedido do usuário); os destinos nunca se sobrepõem: centros a
			-- pelo menos 2 × Radius + CircleGap
			Circles = 2,
			CircleGap = 1,
			-- Visual: cilindro que some em degradê subindo (placas com SurfaceGui + UIGradient)
			WallHeight = 6,
			WallSides = 24,
			WallBottomTransparency = 0.45,
			DiscTop = 0.06, -- o topo do disco fica tanto acima do piso, e ele afunda o resto (nada no mesmo plano do chão)
			HoldTime = 2, -- parado
			MoveTime = 0.35, -- pulando para o próximo lugar
			-- 13/11/2026: × 1,5 com o Coliseu (eram 19 e 12)
			MaxDistance = 28.5, -- o centro do círculo fica até aqui do centro do Coliseu
			MinJump = 18, -- distância mínima de um lugar para o próximo
			-- 12/11/2026 (pedido do usuário): 100–500 💎 e 150% do Cofre (eram 50–200 e 50%)
			-- 13/11/2026 (pedido do usuário): máximo 400 💎 e 200% do Cofre
			-- 14/11/2026 (pedido do usuário): o dobro (eram 100–400 💎 e 200% do Cofre)
			DiamondsMin = 200,
			DiamondsMax = 800,
			VaultShare = 4,
			SecondShare = 0.5,
			HudEvery = 0.25,
			-- Quem está dentro do círculo: contorno amarelo + tinta leve, como no raio do OVNI (09/11/2026, pedido do usuário)
			GlowColor = Color3.fromRGB(255, 215, 60),
			GlowFillTransparency = 0.7,
			GlowOutlineTransparency = 0.15,
		},
		-- Frigo Dourado (nome provisório; Server/Events/GoldenFrigo; 08/11/2026, pedido do usuário). Evento da ilha
		-- (IslandRotation) desde 10/11/2026
		GoldenFrigo = {
			Name = "Frigo Dourado",
			Title = "FRIGO DOURADO",
			Icon = "🐫",
			Goal = "Encoste no Frigo Dourado primeiro!\nGanha 💎 e moedas!",
			Brawl = false,
			Outside = true, -- acontece fora do Coliseu
			-- 18/11/2026 (pedido do usuário): do IslandHideTeamsBefore até o fim, os times seguem em tamanho 0% (sem o
			-- Tamanho do brainrot), na formação normal; Workspace "IslandTeamsZeroSize" → Client/FollowController
			TeamsZeroSize = true,
			-- Passos (17/11/2026, pedido do usuário): um dos dois sorteado a cada StepEvery s enquanto ele anda
			StepEvery = 0.4, -- (era 0,25; volume 1 → 0,6 em 17/11/2026)
			StepSounds = {
				{ Id = "rbxassetid://135037154891351", Volume = 0.6, MinDistance = 30, MaxDistance = 240 },
				{ Id = "rbxassetid://110522236020035", Volume = 0.6, MinDistance = 30, MaxDistance = 240 },
			},
			-- Prêmio de quem encostar (12/11/2026, no molde do Bombardiro e do Rei da Colina): diamantes de DiamondsMin a
			-- DiamondsMax pelo nível do brainrot mais alto + VaultShare do limite do Cofre em moedas (é dourado: moedas)
			-- 13/11/2026 (pedido do usuário): 250–700 💎 (era 150–1.500)
			DiamondsMin = 250,
			DiamondsMax = 700,
			VaultShare = 1,
			-- Perseguição (12/11/2026, pedido do usuário): cada segundo a até ChaseRange studs do Frigo vale ChasePerSecond
			-- (8%; 13/11/2026, pedido do usuário: era 6%, antes 2,5% e 1%) do prêmio de quem pega, pago no fim (até 100%). Quem pegou o Frigo
			-- não ganha isto (só o prêmio inteiro)
			ChaseRange = 60, -- 14/11/2026 (pedido do usuário): +50% (era 40; antes 30)
			ChasePerSecond = 0.08,
			Duration = 60,
			Species = "FrigoCamelo",
			Scale = 1.5, -- 50% maior que um Frigo normal
			SpeedFactor = 2, -- em relação a um jogador correndo fora do Coliseu
			InvulnerableSeconds = 5, -- ao nascer, ninguém pega
			BounceMinTurn = 30, -- ao bater, a nova direção fica pelo menos tantos graus longe da atual
			BounceClearStuds = 100, -- 16/11/2026, pedido do usuário (era 60) -- ao bater, a nova direção precisa ter isso livre à frente
			BounceTestStep = 5, -- de quantos em quantos graus testa as direções
			-- 13/11/2026 (pedido do usuário): era 1.5. Muda de direção a cada ForceTurnEvery s...
			ForceTurnEvery = 0.75,
			ForceTurnMin = 40, -- ...em pelo menos tantos graus, sempre para um lado livre até a próxima troca...
			TurnClearExtra = 0.3, -- ...com esta folga a mais (30% do trecho; sem lugar livre aceita a metade)
			TouchBackExtra = 7, -- a hitbox vai isto a mais para trás, para compensar o atraso da rede (10/11/2026: 3 → 7)
			TouchRadius = 3, -- studs no chão para contar como encostar
			TouchHeight = 12,
			AfterHitBoost = 0.5, -- ao voltar a andar depois de bater, corre tanto a mais (2x do jogador vira 3x)...
			AfterHitBoostSeconds = 0.3, -- ...por este tempo, contado de quando ele volta a andar
			HitStopSeconds = 0.05, -- bateu: fica parado este tempo antes de seguir
			IconHeight = 14,
			IconPixels = 44, -- tamanho máximo do escudo na tela; de longe para na metade disso
			NameHeight = 11, -- nome em cima da cabeça
			NameStuds = Vector2.new(12, 3), -- tamanho no mundo...
			NameMinPixels = Vector2.new(130, 26), -- ...mais este mínimo: de longe ele para de diminuir aqui
			-- Paredes só dele
			CanalApothem = 85, -- volta de fora do canal (fecha as 4 pontes)
			PlotMargin = 1.5, -- folga em volta do piso de cada terreno
			RingFrom = 126, -- anel: procura a partir daqui (depois da rua de fora)...
			RingTo = 330,
			RingStep = 4,
			RingSamples = 96,
			RingMaxGround = 3, -- ...até o chão passar desta altura (montanha) ou virar água
			RingMargin = 8, -- recua tanto do ponto achado
			-- Obstáculos e chão
			ProbeHeight = 3.5, -- altura do centro da esfera que testa o caminho
			ProbeRadius = 2.5,
			TurnLookAhead = 0.15, -- s à frente que precisam estar livres para virar
			GroundProbeUp = 5, -- acima disso pegaria a copa das árvores como se fosse chão
			GroundProbeDown = 40,
			SpawnClearance = 12, -- nasce pelo menos esse tanto longe das paredes
			SpawnTries = 80,
		},
		-- Caça aos Ovos (14/11/2026, pedido do usuário; Server/Events/EggHunt + Client/Controllers/EggHuntController).
		-- Evento da ilha: nascem Count Ovos de Páscoa (EggConfig.Extra.EasterEgg) em lugares sorteados de
		-- Config/EggHuntPoints. Segurar E por HoldDuration pega o ovo e paga na hora: diamantes de DiamondsMin a DiamondsMax
		-- e IncomeSecondsMin a IncomeSecondsMax segundos de renda em moedas, pelo nível do brainrot mais alto (1 a 200;
		-- com o bônus da Torre). Acaba quando pegam todos ou o tempo acaba
		EggHunt = {
			Name = "Caça aos Ovos",
			Title = "CAÇA AOS OVOS",
			Icon = "🐣",
			Goal = "Ache os ovos de Páscoa pela ilha!\nCada ovo: 💎 e moedas na hora!",
			Brawl = false,
			Outside = true, -- acontece fora do Coliseu
			Duration = 60,
			Count = 10,
			Egg = "EasterEgg", -- EggConfig.Extra
			-- 14/11/2026 (pedido do usuário): 50–175 💎 e 75–225 s de renda (eram 50–125 💎 e 50–175 s)
			DiamondsMin = 50,
			DiamondsMax = 175,
			IncomeSecondsMin = 75,
			IncomeSecondsMax = 225,
			HoldDuration = 0.5, -- segurar E
			-- 14/11/2026 (pedido do usuário): durante o evento todo mundo fora do Coliseu fica com o Taco Dourado
			-- (AirdropConfig.Bat) na mão e todos correm SpeedBonus a mais (+40%)
			GoldenBat = true,
			SpeedBonus = 0.4,
			-- 19/11/2026 (pedido do usuário): os times seguem no tamanho 0% (sem o Tamanho do brainrot), como no Frigo
			-- Dourado; Workspace "IslandTeamsZeroSize" → Client/FollowController (de 17 a 19/11 era o tamanho normal,
			-- TeamsNormalSize)
			TeamsZeroSize = true,
			PromptDistance = 10,
			PickSlack = 6, -- folga a mais na distância conferida no servidor (atraso da rede)
			-- Desenho (só no cliente): altura do ovo, quanto sobe e desce, giro e brilhinhos para achar de longe
			EggHeight = 2.8,
			BobHeight = 0.3,
			BobPeriod = 2.2,
			SpinSpeed = 45, -- graus por segundo
			SparkleRate = 3,
			SparkleColor = Color3.fromRGB(255, 236, 150),
		},
		-- Evento Vulcão (16/11/2026, pedido do usuário; Server/Events/Volcano + Client/Controllers/VolcanoController; ilha em
		-- MapConfig.VolcanoIsland). No último minuto antes (Announce) aparece a área verde na faixa bege da praça (Zone);
		-- quem estiver nela quando começar vai para a ilha. Tela treme, o fogo do vulcão acende e bolas de fogo saem dele e
		-- caem em círculos vermelhos (Radius; enchem em Warn s e matam com um golpe). A cada WaveEvery s caem mais e mais
		-- rápido. Morreu ou caiu da ilha: câmera fixa (SpectateCamera) até o fim. Quem sobrevive ao Duration ganha
		Volcano = {
			Name = "Vulcão",
			Title = "ERUPÇÃO DO VULCÃO",
			Icon = "🌋",
			Goal = "Fique na área verde da praça!\nNa ilha, fuja das bolas de fogo!",
			-- Som da explosão no chão (16/11/2026, pedido do usuário): UM por leva de bolas, sorteado entre estes
			ImpactSounds = { "rbxassetid://74149238738530", "rbxassetid://91288569991875" },
			ImpactVolume = 0.288, -- 18/11/2026: -40% (era 0,48); 17/11/2026: -20% (era 0,8) e depois -25% (era 0,64)
			Brawl = false,
			Outside = true, -- acontece fora do Coliseu
			Duration = 45, -- era 60 (16/11/2026)
			-- Área verde: a praça inteira (MapConfig.Spawn.Center) até a borda de fora da faixa bege (Outer = apótema);
			-- WallHeight = altura da parede de luz da borda
			Zone = { Outer = 43.5, WallHeight = 5, Color = Color3.fromRGB(90, 230, 110) },
			Radius = 8.1, -- studs de cada círculo vermelho (era 6; +35% em 16/11/2026)
			Warn = 1.3, -- s do círculo aparecer até a bola cair (enche e mata)
			Flight = 1.3, -- s de voo da bola, contados até a queda (ela sai do vulcão e chega junto com o círculo cheio)
			FallBelow = 12, -- caiu mais que isso abaixo do chão da ilha = fora
			-- Dificuldade: a cada WaveEvery s, uma onda nova; cada rajada tem Volley + VolleyGrow × onda círculos, e entre
			-- rajadas Interval × IntervalDecay ^ onda s (mínimo MinInterval). AimShare = parte que mira em quem está vivo
			WaveEvery = 5, -- era 6 (16/11/2026)
			Volley = 2,
			VolleyGrow = 1,
			Interval = 1.6,
			IntervalDecay = 0.85,
			MinInterval = 0.35,
			AimShare = 0.5,
			AimSpread = 4, -- studs de erro da mira
			SpawnRadius = 28, -- até onde a ilha espalha quem chega
			ShakeSeconds = 2.5,
			ShakeAngle = 1.6, -- graus
			-- Câmera de quem morreu: relativa ao centro do chão da ilha
			SpectateCamera = { Offset = Vector3.new(0, 55, 70), LookAt = Vector3.new(0, 0, 0) },
			-- Prêmio de quem sobrevive até o fim (pelo nível do brainrot mais alto, com o bônus de eventos): diamantes e
			-- VaultShare × limite do Cofre em moedas (4 = 400%). Quem foi e não chegou ao fim: participação
			DiamondsMin = 100,
			DiamondsMax = 800,
			VaultShareMin = 2.4, -- 17/11/2026 (pedido do usuário): -40% (era 4)
			VaultShareMax = 8.4, -- 17/11/2026 (pedido do usuário): -40% (era 14)
			-- Participação: de ParticipationMin a ParticipationMax do prêmio, pelo tempo que ficou vivo na ilha
			ParticipationMin = 0.1,
			ParticipationMax = 0.5,
			-- Taco do centro (EggFieldConfig.Bat) derruba só isso durante o evento (normal: 2 s)
			BatDownSeconds = 0.6, -- 16/11/2026, pedido do usuário (era 0,3)
			FireballColor = Color3.fromRGB(255, 120, 30),
		},
		-- Balão da Fortuna (15/11/2026, pedido do usuário; Server/Events/Balloon + Client/Controllers/BalloonController, caminho em
		-- Shared/Events/BalloonPath). Evento da ilha: um balão roda a ilha e a cada BurstEvery s joga BurstBase + 1 por
		-- jogador moedas em arco, em volta dele (como largar tralhas, só que longe). Encostar pega. Tipos em Coins (Weight
		-- = chance), todos × Reward.bonus (bônus de evento: Torre e rebirth)
		Balloon = {
			Name = "Balão da Fortuna",
			Title = "BALÃO DA FORTUNA",
			Icon = "🎈",
			Goal = "Siga o balão e pegue as moedas!\n⭐ níveis · ⚔️ talento · 💎 · 💰",
			Brawl = false,
			Outside = true, -- acontece fora do Coliseu
			-- 15/11/2026 (pedido do usuário): do IslandHideTeamsBefore (10 s antes) até o fim, os times ficam pequenos
			-- atrás do dono (em vez de sumir) e o Bombardiro de enfeite sai do céu
			TeamsSmall = true,
			ClearSky = true,
			-- 15/11/2026 (pedido do usuário): todos correm SpeedBonus a mais e quem está fora do Coliseu fica com o Taco do
			-- Balão (AirdropConfig.BalloonBat) na mão
			SpeedBonus = 0.3,
			BalloonBat = true,
			BatAfterEnd = 5, -- 19/11/2026 (pedido do usuário): o taco fica mais 5 s depois do fim
			-- 15/11/2026 (pedido do usuário): todos pulam JumpBonus a mais e têm pulo duplo em qualquer lugar da ilha
			-- (DoubleJump num evento com Outside vale fora do Coliseu também; EventService refreshDoubleJump)
			JumpBonus = 0.2,
			DoubleJump = { SmokeSeconds = 0.75 },
			Duration = 60,
			-- Voo: círculo em volta do centro da ilha (dentro do círculo vermelho do desenho do usuário)
			OrbitCenter = Vector3.new(0, 0, 15),
			OrbitRadius = 150,
			OrbitPeriod = 30, -- s para dar uma volta (15/11/2026: era 45, depois 39)
			StartPoints = 6, -- pontos do círculo onde ele pode começar, sorteado a cada evento (16/11/2026, pedido do usuário)
			Height = 45, -- altura do cesto (15/11/2026: 10 mais baixo, era 55)
			BobHeight = 1.5,
			BobPeriod = 4,
			ArriveSeconds = 3, -- desce do céu no começo
			ArriveFrom = 60, -- de quantos studs acima
			-- Rajadas
			BurstEvery = 6,
			FirstBurstAt = 3,
			BurstBase = 6, -- 16/11/2026 (pedido do usuário): era 5 (antes 3)
			BurstPerPlayer = 1,
			ThrowMin = 45.5, -- distância no chão do ponto embaixo do balão (15/11/2026: +30%, era 35–95)
			ThrowMax = 123.5,
			AngleJitter = 0.6, -- fração do espaço entre duas moedas que o ângulo pode variar
			ThrowTries = 8, -- lugar proibido: sorteia de novo até tanto
			FlightBase = 1.2, -- tempo de voo = FlightBase + distância / FlightSpeed
			FlightSpeed = 70,
			ArcHeight = 18, -- quanto o arco sobe acima da linha reta
			-- Onde pode cair: dentro de LandRadius do centro da ilha, no chão (nem telhado, nem árvore, nem água) e fora dos
			-- rabiscos do usuário: terrenos (Floor + PlotMargin), canal, centro da praça e Fusão
			LandRadius = 225,
			MaxGroundY = 4,
			PlotMargin = 4,
			Forbidden = {
				{ Center = Vector3.new(0, 0, 0), From = 57, To = 88 }, -- canal (Moat 63–82)
				{ Center = Vector3.new(0, 0, 160), To = 36 }, -- centro da praça (fonte)
				{ Center = Vector3.new(106.05, 0, 143.04), To = 34 }, -- Fusão
			},
			-- Moedas
			CoinDiameter = 4.8, -- 15/11/2026 (pedido do usuário): moeda e encostar +50% (era 3,2; 0,6; 2; 5; 8)
			CoinThickness = 0.9,
			CoinHover = 3, -- altura do centro da moeda acima do chão (subiu junto, senão a moeda maior entra no chão)
			HaloDiameter = 14, -- brilho no chão em volta da moeda (15/11/2026: 2x, era 7)
			-- Luz de verdade embaixo do cesto apontando para o chão (SpotLight; 15/11/2026, pedido do usuário, no lugar do
			-- brilho desenhado). Range máximo do Roblox = 60 (o cesto fica a ~43 do chão)
			Light = { Color = Color3.fromRGB(255, 215, 90), Brightness = 4, Range = 60, Angle = 70, Shadows = true },
			SpinSpeed = 120, -- graus por segundo
			PickRadius = 8.625, -- encostar (no chão; 15/11/2026: +15% a pedido do usuário, era 7,5)
			PickHeight = 13.8, -- 15/11/2026: +15% junto (era 12)
			-- Cada moeda vive Lifetime s depois de cair, mesmo depois do fim do evento, e pisca nos últimos BlinkSeconds
			-- (15/11/2026, pedido do usuário: era 25 e todas sumiam juntas no fim do evento)
			Lifetime = 20,
			BlinkSeconds = 3,
			Coins = {
				-- 16/11/2026 (pedido do usuário): 💰 + 💎 = 70% das moedas (eram 65%), ⚔️ + ⭐ = 30%
				-- 17/11/2026 (pedido do usuário): -30% de ouro, era VaultShare 0.6
				Gold = { Weight = 37, VaultShare = 0.42, Symbol = "💰", Color = Color3.fromRGB(255, 200, 40) },
				Diamond = { Weight = 33, Diamonds = 60, Symbol = "💎", Color = Color3.fromRGB(90, 220, 255) },
				Talent = {
					Weight = 16,
					Talent = 16, -- +16 por moeda (17/11/2026; era 7, antes 5 e 3)
					Symbol = "⚔️",
					Color = Color3.fromRGB(120, 170, 255),
				},
				Level = { Weight = 14, Levels = 8, Symbol = "⭐", Color = Color3.fromRGB(255, 240, 120) }, -- +8 (20/11/2026), sem o bônus dos eventos (16/11/2026)
			},
			CoinColor = Color3.fromRGB(245, 190, 40),
			CoinRimColor = Color3.fromRGB(205, 145, 25),
			SayCooldown = 3, -- "equipe um brainrot" no máximo a cada tanto
		},
		CosmicEgg = {
			Name = "Ovo Cósmico",
			Title = "OVO CÓSMICO", -- em maiúsculas (o string.upper do Luau não mexe nos acentos)
			Icon = "🥚",
			Goal = "Segure o ovo até o fim!\nGanha o Ovo Cósmico!",
			Brawl = false, -- briga entre brainrots tirada (BrawlConfig.PvP = false)
			-- Os times dos jogadores não aparecem no Coliseu durante o evento (10/11/2026, pedido do usuário)
			HideTeams = true,
			-- Pulo duplo dentro do Coliseu enquanto vale (Client/DoubleJumpController; pedido do usuário, 06/11/2026):
			-- o 2º pulo tem a altura do 1º; a fumacinha do pé some em SmokeSeconds
			DoubleJump = { SmokeSeconds = 0.75 },

			Visible = 60, -- duração: chegou a zero, quem está com o ovo ganha na hora (08/11/2026, sem o "??")
			Overtime = 10, -- ovo solto no fim: quem pegar primeiro ganha, até este tempo
			FallTime = 2, -- o ovo cai do céu no centro
			FallHeight = 90, -- 13/11/2026: era 60 (o telão do Coliseu maior vai até ~87 de altura: o ovo cai de cima dele)

			EggHeight = 3.2, -- só para pré-carregar a malha (EventStageController); o tamanho de verdade vem do VisualSize
			-- 14/11/2026 (pedido do usuário): o ovo do evento aparece como um ovo do campo de VisualSize% (altura =
			-- EggFieldConfig.EggHeight × SizeConfig.eggScale, igual no chão e na cabeça) e o círculo embaixo dele cresce
			-- na mesma escala (PickRadius × eggScale)
			VisualSize = 250,
			PickRadius = 4, -- encostar no ovo solto (studs, no chão), para um ovo de 0%; o de verdade = × eggScale(VisualSize)
			PrizeMinSize = 250, -- o ovo ganho no evento vem com pelo menos este tamanho (14/11/2026; Bombardiro continua 80%)
			-- Encostar em quem carrega rouba o ovo na hora (08/11/2026, pedido do usuário). Hitbox afinada em 12/11/2026
			-- (pedido do usuário; era raio 4, compensação 0,3 s e altura sem limite): raio no chão entre as raízes...
			StealRadius = 3.38, -- 14/11/2026 (pedido do usuário): +30% (era 2,6; antes 2)
			-- ...e altura: quem rouba pode estar até StealAbove studs acima de quem carrega (pulando em cima) e até
			-- StealBelow abaixo
			StealAbove = 7,
			StealBelow = 11, -- 14/11/2026 (pedido do usuário): +6 para baixo (era 5; antes 3)
			-- Compensação de atraso: na tela do jogador, quem corre com o ovo aparece um pouco atrás de onde está de verdade no
			-- servidor. Vale também encostar onde ele estava há este tempo (segundos)
			StealLagSeconds = 0.15,
			StealBackLock = 0.5, -- quem perdeu o ovo fica este tempo sem poder pegar de novo
			TakeImmunity = 1.5, -- quem acabou de pegar não pode ser roubado nesse tempo (buff "Invulnerable")
			TakeBoost = 1.3, -- e corre tanto a mais (+130% desde 12/11/2026; era +90%)...
			TakeBoostSeconds = 1.5, -- ...por este tempo
			PlayerBats = false, -- taco dos jogadores desligado por enquanto (08/11/2026, pedido do usuário)
			CarrierSpeed = 0.75, -- quem carrega fica 25% mais lento (jogadores e bots; 15% até 13/11/2026, 30% até 12/11/2026)

			-- Tentou sair com ele ou levou tacada: o ovo cai no chão (08/11/2026, pedido do usuário). Saindo, cai no último lugar
			-- válido, DropInward studs para dentro, na direção do centro; levando tacada, ali mesmo
			-- Área do evento: o Coliseu inteiro, até a parede de fora, com os 4 portões bloqueados (08/11/2026, pedido do usuário)
			-- 13/11/2026: área e portões × 1,5 com o Coliseu (eram 49; portão 50,5 / 3 / 18,2 / 14; LED 48,3 / 17,8 / 0,35)
			ArenaApothem = 73.5,
			Gates = {
				Distance = 75.75, -- do centro até o meio da parede do portão
				Thickness = 4.5,
				Width = 27.3, -- o vão tem 27
				Height = 21, -- até o topo do arco
				OneWay = true, -- quem está fora atravessa e entra; quem está dentro não sai (false = fecha para todos)
				StripDistance = 72.45, -- LED no chão, logo antes do bloqueio
				StripLength = 26.7,
				StripY = 0.525, -- o piso do portão fica em 0,45: o LED fica um pouco acima, sem faces no mesmo plano
				-- grossura e altura do LED (as mesmas do LED em volta da arena, ZoneEdge)
				StripWidth = 1.29,
				StripHeight = 0.75,
			},
			DropInward = 5,
			-- Rede de segurança (08/11/2026, pedido do usuário): a cada SafetyEvery s, ovo fora do Coliseu (mais SafetyMargin studs de
			-- folga) ou acima de SafetyMaxHeight volta para o centro, mesmo na cabeça de alguém
			SafetyEvery = 2,
			SafetyMargin = 9, -- 13/11/2026: era 6 (Coliseu 50% maior)
			SafetyMaxHeight = 120, -- em cima de um poste, com pulo duplo e a árvore de skills, passava de 40 (13/11/2026: era 80)
			DropTime = 0.45, -- o arco até o chão (igual ao de largar tralha)
			DropArc = 1.6, -- studs que sobe no meio do caminho
			DropLock = 0.3, -- e espera antes de poder ser pego
			-- Bots de teste que imitam jogadores (Server/Events/EggDebugBots): botão "+ Bot" do DEV durante o evento
			DebugBots = {
				Tag = "EggDebugBot",
				Max = 8,
				SpawnArea = 0.6, -- fração do raio do Coliseu onde nascem
				EdgeArea = 0.95, -- não passam desta fração da área do evento (ArenaApothem), inclui arquibancada e portões
				DoubleJumpDelay = 0.3, -- segundos depois de pular: o segundo pulo, se precisar
				StepProbeHeight = 1.2, -- altura acima do pé onde procura obstáculo à frente
				StepProbeAhead = 3.5, -- studs à frente: bateu em algo, pula
				JumpMinDistance = 3, -- preso e com o destino mais longe que isso: pula (degraus da arquibancada)
				FleeRadius = 60, -- só fogem de quem está até aqui (13/11/2026: era 40; Coliseu 50% maior)
				FleeStep = 27, -- studs à frente para onde correm (era 18)
				ReactionSeconds = 0.5, -- alguém pegou o ovo: tempo até os bots começarem a seguir (andam a esmo até lá)
				WanderEvery = 3, -- sem o ovo: a cada tantos segundos...
				WanderSeconds = 0.5, -- ...anda este tempo em linha reta numa direção sorteada
			},
			-- Tung Tung Tung Sahur do evento (Server/Events/EggBot; 08/11/2026, pedido do usuário)
			Bot = {
				Tag = "EggBot",
				-- Grupos de colisão: o Tung atravessa jogadores e bots, mas continua pisando no chão
				BodyGroup = "EggBotBody",
				Species = "TungTungTungSahur",
				DisplayName = "Tung Tung Tung Sahur",
				SpeedFactor = 0.46552, -- da velocidade de um jogador (16/11/2026: +15% de novo, era 0,4048; 14/11/2026: +15%, era 0,352; antes 0,32)
				SpawnOffset = Vector3.new(36, 0, 0), -- a partir do centro do Coliseu (13/11/2026: era 24)
				Attacks = { "attack", "attack2" },
				AttackRange = 7, -- studs: começa o golpe (o acerto usa a hitbox do taco)
				-- Sem ninguém com o ovo: não persegue; só bate em quem entrar nesta caixa (studs, em volta dele)
				GuardBox = 5,
				IntroSeconds = 1, -- no começo do evento: ri parado este tempo antes de andar
				LaughSeconds = 0.85, -- depois de acertar: ri parado
				RestSeconds = 3, -- depois de rir: continua parado, sem atacar, e só então volta a perseguir
				IdleExtraEvery = 5, -- sem alvo: "idle_2" por cima da "idle" a cada tantos segundos
				JumpHeight = 15.625, -- 16/11/2026 (pedido do usuário): +25% de novo (era 12,5; 14/11/2026: era 10)
				JumpWhenAbove = 2.5, -- o alvo está tantos studs acima: pula
				JumpRange = 16, -- ... se estiver até esta distância
				StuckCheck = 0.6, -- a cada tantos segundos confere se ficou preso
				StuckStuds = 1.5, -- andou menos que isso: pula
			},

			-- Participantes que precisa ter para o vencedor levar o ovo (com menos, leva NoEggPrizeSeconds de R).
			-- 0 = sempre dá o ovo, até sozinho: decisão do usuário (03/11/2026). O design sugeria 4 para ninguém
			-- farmar sozinho num servidor vazio; rever no balanceamento (etapa 10).
			MinParticipantsForEgg = 0,
			NoEggPrizeSeconds = 135,
			ConsolationSeconds = 45,
			ConsolationMin = 150,
			StealBonusSeconds = 10,
			StealBonusMax = 3,
			-- Prêmio por segurar o ovo (17/11/2026, pedido do usuário; antes só quem mais segurou levava): TODO jogador que
			-- segurou pelo menos MinSeconds leva, subindo em linha reta até MaxSeconds (mais que isso = o máximo):
			-- Diamonds = 💎 e VaultShare = parte do limite do Cofre em moedas (0.2 = 20%). Os dois × (1 + TopLevelBonus ×
			-- nível do brainrot mais alto, 1 → 0 e 200 → 1): com nível 200 dobram. Depois, o bônus de eventos (Reward.bonus)
			HoldPrize = {
				MinSeconds = 1,
				MaxSeconds = 25,
				Diamonds = { Min = 10, Max = 200 },
				VaultShare = { Min = 0.2, Max = 3 },
				TopLevelBonus = 1,
			},
		},
	},

	-- Empurrão em jogador (roubo do ovo, Rei do Ringue): o servidor segura a física por este tempo
	PushTime = 0.25,
	PushLift = 12, -- velocidade para cima no empurrão (sai um pouquinho do chão)
}

-- Config de um evento pelo id
function EventConfig.get(id: string): { [string]: any }?
	return EventConfig.Events[id]
end

return EventConfig
]=]
SOURCES["src/shared/Config/MutationConfig.luau"] = [=[
--[[
	MutationConfig — mutações dos brainrots (19/11/2026, pedido do usuário; começo do sistema de mutações dele).
	O brainrot guarda brainrot.Mutation = id (sem = normal). Igual no servidor e no cliente.
	Uma mutação por brainrot (20/11/2026, pedido do usuário): Dourado e Arco-íris nunca juntos.

	Cada mutação:
	  Name, Color   → texto e cor nos balões ("Dourado")
	  HatchText     → texto que bate na tela ao abrir ovo / na fusão ("DOURADO!")
	  Rainbow       → textos em arco-íris (RarityPaint) em vez da cor Color
	  Order         → mais alto = mais raro (a fusão e o sorteio do ovo tentam do mais raro para o mais comum)
	  Icon          → ícone ao lado das estrelas (Client/UI/PixelIcon, desenho do usuário; Client/UI/MutationIcon)
	  StatBonus     → +% nos atributos, em cima de base + nível + talento + tamanho; o artefato vem DEPOIS e conta em
	                  cima disso (BrainrotStats.breakdown)
	  GoldBonus     → +% nas moedas/s do pedestal (2 = +200% = 3x; Gold.perSecond)
	  Look          → visual do modelo (BrainrotModel.applyMutation):
	      PartColor / Material / Reflectance → a peça de baixo de cada cubo (metal)
	      Tint                → cor que multiplica a textura (Texture.Color3)
	      TextureTransparency → quanto da textura deixa o metal aparecer por baixo (só nos cubos sólidos)
	      Rainbow             → { Spread, Speed, PartSaturation, TintSaturation }: cada cubo com a cor do arco-íris pela
	                            posição na diagonal do modelo (Spread = voltas do arco-íris de um canto ao outro); no
	                            mundo as cores andam (Speed = voltas por segundo; MutationFxController)
	  Fx            → brilhos no mundo (Client/Controllers/MutationFxController):
	      ShineEvery          → s entre as passadas de brilho (faixa clara que atravessa o modelo na diagonal)
	      ShineTime, ShineWidth, ShineColor → duração da passada, largura da faixa (fração do modelo), cor
	      SparkleEvery        → { min, max } s entre as rajadas de brilhinhos
	      SparkleCount, SparkleColors → quantos por rajada e as cores
	      SparkleSize         → tamanho do brilhinho = altura do modelo × isto
]]

local MutationConfig = {}

MutationConfig.Mutations = {
	Golden = {
		Name = "Dourado",
		Color = Color3.fromRGB(255, 205, 50),
		HatchText = "DOURADO!",
		Order = 1,
		Icon = "Golden",
		StatBonus = 0.25,
		GoldBonus = 2,
		Look = {
			PartColor = Color3.fromRGB(255, 196, 30),
			Material = Enum.Material.Metal,
			Reflectance = 0.45,
			Tint = Color3.fromRGB(255, 232, 100),
			TextureTransparency = 0.5,
		},
		Fx = {
			ShineEvery = 2, -- 19/11/2026 (pedido do usuário; era 4)
			ShineTime = 0.7,
			ShineWidth = 0.35,
			ShineColor = Color3.fromRGB(255, 255, 235),
			SparkleEvery = { 1.2, 2.4 },
			SparkleCount = 6,
			SparkleSize = 0.18, -- tamanho do brilhinho = altura do modelo × isto (0,6 a 5 studs)
			SparkleColors = {
				Color3.fromRGB(255, 252, 64),
				Color3.fromRGB(255, 255, 255),
				Color3.fromRGB(255, 226, 42),
			},
		},
	},
	-- Arco-íris (20/11/2026, pedido do usuário; ícone desenhado por ele): +50% nos atributos, +500% nas moedas/s,
	-- visual de arco-íris andando pelo corpo, como as coisas Prismáticas
	Rainbow = {
		Name = "Arco-íris",
		Color = Color3.fromRGB(255, 120, 220),
		HatchText = "ARCO-ÍRIS!",
		Rainbow = true,
		Order = 2,
		Icon = "Rainbow",
		StatBonus = 0.5,
		GoldBonus = 5,
		Look = {
			PartColor = Color3.fromRGB(255, 160, 220), -- só de reserva (as cores vêm do Rainbow)
			Material = Enum.Material.SmoothPlastic,
			Reflectance = 0.25,
			Tint = Color3.fromRGB(255, 220, 245),
			-- Textura OPACA, a cor vem só da tinta (20/11/2026, bug do usuário): com textura meio transparente, onde dois cubos
			-- se sobrepõem (peito/barriga do Tung, juntas) as duas texturas ficavam uma por cima da outra e a faixa saía mais
			-- escura/de outra cor, e mudava de lugar com a animação
			TextureTransparency = 0,
			-- Spread 0 (20/11/2026, pedido do usuário): o corpo inteiro na MESMA cor, mudando junto. Força 35% menor no
			-- mesmo dia (pedido do usuário; era 0,75). A tinta agora é a cor toda (a peça fica escondida atrás da textura)
			-- 20/11/2026 (pedido do usuário: fraco e escuro nos brainrots de textura escura, como o Tung): a cor forte vem
			-- de um Highlight por cima do modelo inteiro (MutationFxController; HighlightSaturation/HighlightFill = quanto
			-- cobre, 0 = cor chapada), que não depende da textura nem empilha onde os cubos se sobrepõem. A tinta da
			-- textura fica leve (ela escurece). Speed 50% mais rápido (era 0,35)
			Rainbow = {
				Spread = 0,
				Speed = 0.42, -- 20% mais lento (20/11/2026, pedido do usuário; era 0,525)
				PartSaturation = 0.49,
				TintSaturation = 0.25,
				HighlightSaturation = 0.85,
				HighlightFill = 0.59, -- 25% menos cor (20/11/2026, pedido do usuário; era 0,45 = 55% de cor, agora 41%)
			},
		},
		Fx = {
			ShineEvery = 2.5,
			ShineTime = 0.7,
			ShineWidth = 0.35,
			ShineColor = Color3.fromRGB(255, 255, 255),
			SparkleEvery = { 1, 2 },
			SparkleCount = 8,
			SparkleSize = 0.18,
			-- Cada brilhinho de uma cor qualquer do arco-íris (20/11/2026, pedido do usuário: saíam quase brancos);
			-- SparkleColors fica só de reserva
			SparkleRandomHue = true,
			SparkleColors = {
				Color3.fromRGB(255, 80, 110),
				Color3.fromRGB(120, 255, 120),
				Color3.fromRGB(110, 170, 255),
			},
		},
	},
}

-- Do mais raro para o mais comum (sorteio do ovo e da fusão)
MutationConfig.ByRarity = { "Rainbow", "Golden" }

-- Chance de cada mutação ao abrir QUALQUER ovo (19/11/2026, pedido do usuário: 2% de Dourado). Sorteio no
-- EggService:Grant; a Sorte não mexe nisto
MutationConfig.EggChance = {
	Golden = 0.02,
	Rainbow = 0.003, -- 0,3% (20/11/2026, pedido do usuário)
}

-- Sorteia a mutação de um brainrot que sai de ovo (nil = normal). `multiplier` = rebirths
-- (RebirthConfig.mutationMultiplier; 20/11/2026)
function MutationConfig.rollEgg(rng: Random, multiplier: number?): string?
	local roll = rng:NextNumber()
	for _, id in MutationConfig.ByRarity do
		local chance = (MutationConfig.EggChance[id] or 0) * (multiplier or 1)
		if roll < chance then
			return id
		end
		roll -= chance
	end
	return nil
end

function MutationConfig.get(id: any): any?
	return if type(id) == "string" then MutationConfig.Mutations[id] else nil
end

-- Mutação do brainrot (dados salvos), ou nil
function MutationConfig.of(brainrot: any): any?
	return if type(brainrot) == "table" then MutationConfig.get(brainrot.Mutation) else nil
end

-- Cor do arco-íris num ponto (0 a 1 = uma volta inteira), com a saturação dada (Look.Rainbow)
function MutationConfig.rainbowColor(position: number, saturation: number): Color3
	return Color3.fromHSV(position % 1, saturation, 1)
end

-- +% nos atributos do brainrot (0 sem mutação)
function MutationConfig.statBonus(brainrot: any): number
	local mutation = MutationConfig.of(brainrot)
	return if mutation then mutation.StatBonus or 0 else 0
end

-- +% nas moedas/s do brainrot (0 sem mutação)
function MutationConfig.goldBonus(brainrot: any): number
	local mutation = MutationConfig.of(brainrot)
	return if mutation then mutation.GoldBonus or 0 else 0
end

return MutationConfig
]=]
SOURCES["src/shared/Config/RarityConfig.luau"] = [=[
--[[
	RarityConfig — as 7 raridades dos brainrots (e dos itens da Máquina de Vendas), da mais comum à mais rara.

	A última tem o id interno "Secret" (guardado nos saves e nas configs), mas se chama **Prismático** desde
	06/11/2026 (pedido do usuário): Rainbow = true, os textos e o que tem a cor dela ficam em arco-íris
	(Shared/Util/RarityPaint + Client/Controllers/RainbowController).

	StatMultiplier: sem uso desde 05/11/2026 (a raridade já está nos stats base da espécie).
	SellValue: moedas ao vender no nível 1 (sobe 10% por nível, ver BrainrotConfig).
	Income: moedas por segundo que o brainrot rende exposto no terreno (vão para o Cofre).
]]

export type Rarity = {
	Id: string,
	Name: string,
	Order: number, -- 1 = Comum ... 7 = Prismático
	Color: Color3,
	StatMultiplier: number,
	SellValue: number,
	Income: number,
	Rainbow: boolean?, -- Prismático: cor em arco-íris nas telas e no mundo
}

local LIST: { Rarity } = {
	{
		Id = "Common",
		Name = "Comum",
		Order = 1,
		Color = Color3.fromRGB(170, 170, 170),
		StatMultiplier = 1,
		SellValue = 10,
		Income = 1,
	},
	{
		Id = "Uncommon",
		Name = "Incomum",
		Order = 2,
		Color = Color3.fromRGB(80, 200, 90),
		StatMultiplier = 1.3,
		SellValue = 30,
		Income = 3,
	},
	{
		Id = "Rare",
		Name = "Raro",
		Order = 3,
		Color = Color3.fromRGB(60, 140, 255),
		StatMultiplier = 1.7,
		SellValue = 90,
		Income = 6,
	},
	{
		Id = "Epic",
		Name = "Épico",
		Order = 4,
		Color = Color3.fromRGB(170, 80, 230),
		StatMultiplier = 2.2,
		SellValue = 300,
		Income = 15,
	},
	{
		Id = "Legendary",
		Name = "Lendário",
		Order = 5,
		Color = Color3.fromRGB(255, 170, 30),
		StatMultiplier = 3,
		SellValue = 1200,
		Income = 40,
	},
	{
		Id = "Mythic",
		Name = "Mítico",
		Order = 6,
		Color = Color3.fromRGB(255, 60, 90),
		StatMultiplier = 4,
		SellValue = 5000,
		Income = 100,
	},
	{
		-- Prismático (era "Secreto", preto): arco-íris; Color é o tom parado de quando não dá para animar
		Id = "Secret",
		Name = "Prismático",
		Order = 7,
		Color = Color3.fromRGB(255, 120, 230),
		Rainbow = true,
		StatMultiplier = 5.5,
		SellValue = 25000,
		Income = 250,
	},
}

local byId: { [string]: Rarity } = {}
for _, rarity in LIST do
	byId[rarity.Id] = rarity
end

local RarityConfig = {
	List = LIST,
}

function RarityConfig.get(id: string): Rarity
	return byId[id] or LIST[1]
end

-- Cor para texto (o arco-íris do Prismático é posto por cima pelo RarityPaint)
function RarityConfig.textColor(id: string): Color3
	return RarityConfig.get(id).Color
end

-- Nome em RichText (texto com várias cores numa linha só, onde não dá para animar): o Prismático sai com cada
-- letra de uma cor do arco-íris
function RarityConfig.richName(id: string, text: string?): string
	local rarity = RarityConfig.get(id)
	local name = text or rarity.Name
	if not rarity.Rainbow then
		return `<font color="#{rarity.Color:ToHex()}">{name}</font>`
	end
	local letters = {}
	local count = utf8.len(name) or #name
	local index = 0
	for _, code in utf8.codes(name) do
		local hue = (index / math.max(1, count)) * 0.85
		index += 1
		table.insert(letters, `<font color="#{Color3.fromHSV(hue, 0.7, 1):ToHex()}">{utf8.char(code)}</font>`)
	end
	return table.concat(letters)
end

return RarityConfig
]=]
SOURCES["src/shared/Config/SizeConfig.luau"] = [=[
--[[
	SizeConfig — o tamanho dos brainrots (12/11/2026, pedido do usuário).

	Cada brainrot tem brainrot.Size = % a mais de tamanho, de 0 a Max (400 desde 12/11/2026; era 200). Não tem barra nem
	como melhorar: vem do ovo do campo e dos ovos de evento (sorteio por EggBands; os outros ovos dão 0) e a fusão mantém
	o da base.

	  - Força: até StatBonusAtMax (+200%) a mais nos stats, proporcional (Shared/Brainrot/BrainrotStats), e o mesmo nas
	    moedas/s do pedestal (Shared/Brainrot/Gold).
	  - Lutas (Torre, Chefão, PvP, evento Arena): os stats são os mesmos de fora (13/11/2026, pedido do usuário; de 12 a
	    13/11 o tamanho valia a metade); só o modelo fica menor (battleModelScale).
	  - Visual: o modelo fica 1 + Size/100 vezes maior (400% = 5x) no time que segue o jogador e no pedestal; na luta,
	    um sexto (BattleVisualShare, battleModelScale: 400% = 1,67x; 14/11/2026, era um quinto). Os chefes da Torre usam TowerConfig.MiniBossSize/BossSize e o
	    Chefão o Size da dificuldade (TowerBossConfig), só no visual (a força continua a do TowerConfig/TowerBossConfig).
	  - Nome: pelas faixas de Names (Minúsculo até 30%, Pequeno, Médio, Grande, Muito grande, Enorme, Gigante, Golias, Titã).
	  - Ovo do campo: o ovo aparece maior (EggScaleSteps) e não mostra o número.

		SizeConfig.clamp(size)          → 0..Max
		SizeConfig.name(size)           → "Minúsculo" ... "Titã"
		SizeConfig.statMultiplier(size) → 1 a 3 (stats e moedas/s)
		SizeConfig.modelScale(size)     → 1 a 5 (visual do brainrot)
		SizeConfig.battleModelScale(size) → 1 a 1,67 (visual do brainrot nas lutas)
		SizeConfig.eggScale(size)       → 1 a 9,2 (visual do ovo do campo, do ninho do lugar e do ovo na cabeça)
		SizeConfig.followSpread(maior)  → 1 a 3.3 (afastamento dos lados do time que segue)
		SizeConfig.battleHalfWidth(escala) → 0 a 0,5 stud (largura a mais de cada lado na fila das lutas)
		SizeConfig.followBack(tamanho)  → studs que o do meio do time que segue recua
		SizeConfig.rollEgg(rng)         → tamanho sorteado de um ovo do campo (inteiro)
		SizeConfig.rollEven(rng, mínimo) → inteiro de mínimo a Max, todos com a mesma chance (ovos de evento)
]]

local SizeConfig = {
	Max = 400,
	StatBonusAtMax = 2, -- +200% nos stats (e nas moedas/s) com o tamanho máximo (200% de tamanho = +100%, como antes)
	-- nas lutas o modelo cresce um sexto do tamanho (só visual; 13/11/2026 um quinto, 14/11/2026 um sexto: pedido do
	-- usuário, o da ponta da fila saía da tela)
	BattleVisualShare = 1 / 6,
	-- Nome pelo tamanho: o primeiro com UpTo >= tamanho (12/11/2026, faixas do usuário; antes eram 6 nomes de 66,7% cada)
	Names = {
		{ Name = "Minúsculo", UpTo = 30 },
		{ Name = "Pequeno", UpTo = 60 },
		{ Name = "Médio", UpTo = 100 },
		{ Name = "Grande", UpTo = 150 },
		{ Name = "Muito grande", UpTo = 200 },
		{ Name = "Enorme", UpTo = 250 },
		{ Name = "Gigante", UpTo = 300 },
		{ Name = "Golias", UpTo = 350 },
		{ Name = "Titã", UpTo = 400 },
	} :: { { Name: string, UpTo: number } },
	-- Sorteio dos ovos com tamanho: Chance de cair na faixa [From, To), de 25 em 25%, cada faixa mais rara que a de baixo.
	-- 12/11/2026 (pedido do usuário, última versão): 85% dos ovos de 0 a 125%. Até 175% cada faixa é 74% da de baixo;
	-- de 175% em diante a queda forte (~60% da anterior) e 0,1% de 325% em diante. 200%+ = 2,46%, média ~66%
	-- (antes: 78% até 125%, 200%+ = 3,9%, média ~80%)
	EggBands = {
		{ Chance = 0.2840, From = 0, To = 25 },
		{ Chance = 0.2102, From = 25, To = 50 },
		{ Chance = 0.1555, From = 50, To = 75 },
		{ Chance = 0.1151, From = 75, To = 100 },
		{ Chance = 0.0852, From = 100, To = 125 },
		{ Chance = 0.0630, From = 125, To = 150 },
		{ Chance = 0.0466, From = 150, To = 175 },
		{ Chance = 0.0158, From = 175, To = 200 },
		{ Chance = 0.0094, From = 200, To = 225 },
		{ Chance = 0.0056, From = 225, To = 250 },
		{ Chance = 0.0034, From = 250, To = 275 },
		{ Chance = 0.0020, From = 275, To = 300 },
		{ Chance = 0.0012, From = 300, To = 325 },
		{ Chance = 0.001, From = 325, To = 350 },
		{ Chance = 0.001, From = 350, To = 375 },
		{ Chance = 0.001, From = 375, To = 400 },
	},
	-- Escala visual do ovo (no chão, o ninho do lugar e na cabeça/na mão, que têm o MESMO tamanho; 12/11/2026, pedido do
	-- usuário, versão final do dia): a partir de From% de tamanho, cada 1% a mais de tamanho soma Per à escala, e as
	-- faixas vão somando: 1% até 150%, +0,4 (1,4%) até 200%, +0,6 (2%) até 300%, +1 (3%) até 350% e +2 (5%) até 400%.
	-- Resultado: 150% = 2,5x, 200% = 3,2x, 300% = 5,2x, 350% = 6,7x, 400% = 9,2x. Tamanho em studs = EggFieldConfig.EggHeight × isso
	EggScaleSteps = {
		{ From = 0, Per = 0.01 },
		{ From = 150, Per = 0.014 },
		{ From = 200, Per = 0.02 },
		{ From = 300, Per = 0.03 },
		{ From = 350, Per = 0.05 },
	} :: { { From: number, Per: number } },
	-- Lutas (Torre, Chefão, PvP; Client/BattleController): na fila, cada brainrot ocupa BattleHalfWidth studs a mais de
	-- CADA lado por unidade de escala acima de 1 (400% = 1,8x na luta = +0,6 de cada lado). A fila soma as larguras: os
	-- espaços entre um e outro ficam iguais (13/11/2026, pedido do usuário; antes era +40% na distância de cada um; 2
	-- espalhava demais, o da ponta saía da tela)
	BattleHalfWidth = 0.75,
	-- Time que segue o jogador (Client/FollowController; 12/11/2026, pedido do usuário): com algum brainrot do time de
	-- AtLeast% de tamanho para cima, os lugares da esquerda e da direita se afastam Extra (0.6 = 60% mais longe do meio),
	-- para os grandes não se atravessarem. Vale a maior faixa alcançada
	-- 12/11/2026, depois (pedido do usuário): a partir de 150% +60% (40% + 20%), 200% +80% (+20%), 250% +110% (+30%) e
	-- 300% +130% (+20%); era +40% acima de 150% e +65% acima de 300%
	-- 12/11/2026, de novo: 250% +130% (era +110%) e cada 50% depois +20% a mais: 300% +150%, 350% +170%, 400% +190%
	-- 13/11/2026 (pedido do usuário): de 300% para cima +20% a mais, e de 350% para cima mais +20%
	-- O do meio (atrás do dono) recua FollowBack.Studs a cada FollowBack.Every% do tamanho DELE (13/11/2026, pedido do
	-- usuário: 1 stud a cada 100%; antes 2 a cada 50%)
	FollowBack = { Every = 100, Studs = 1 },
	FollowSpread = {
		{ AtLeast = 150, Extra = 0.6 },
		{ AtLeast = 200, Extra = 0.8 },
		{ AtLeast = 250, Extra = 1.3 },
		{ AtLeast = 300, Extra = 1.7 },
		{ AtLeast = 350, Extra = 2.1 },
		{ AtLeast = 400, Extra = 2.3 },
	},
}

function SizeConfig.clamp(size: any): number
	return math.clamp(tonumber(size) or 0, 0, SizeConfig.Max)
end

function SizeConfig.name(size: any): string
	local value = SizeConfig.clamp(size)
	for _, entry in SizeConfig.Names do
		if value <= entry.UpTo then
			return entry.Name
		end
	end
	return SizeConfig.Names[#SizeConfig.Names].Name
end

-- Parte do bônus de stats (0 a StatBonusAtMax)
function SizeConfig.statShare(size: any): number
	return SizeConfig.clamp(size) / SizeConfig.Max * SizeConfig.StatBonusAtMax
end

function SizeConfig.statMultiplier(size: any): number
	return 1 + SizeConfig.statShare(size)
end

function SizeConfig.modelScale(size: any): number
	return 1 + SizeConfig.clamp(size) / 100
end

-- Escala do modelo nas lutas por turnos (Torre, Chefão, PvP, evento Arena): cada ponto de tamanho vale BattleVisualShare
-- (400% = 1 + 80% = 1,8x). Só visual: os stats na luta são os de sempre.
-- Barras de vida da luta sobem com o tamanho (17/11/2026, pedido do usuário; refeito em 18/11/2026): com 0% a barra
-- fica BarAboveHead studs acima da cabeça do modelo (altura dele na luta) e sobe em linha reta até BarMaxHeight
-- studs acima da base com BarLiftFullAt% de tamanho; acima disso não muda (antes: 7,2 para todos + até 3,5)
SizeConfig.BarMaxHeight = 10.7
SizeConfig.BarAboveHead = 1
SizeConfig.BarLiftFullAt = 300

-- Altura da barra acima da base do modelo; modelHeight = a altura do modelo na luta (studs, já com a escala)
function SizeConfig.battleBarHeight(size: any, modelHeight: number): number
	local low = math.min(SizeConfig.BarMaxHeight, modelHeight + SizeConfig.BarAboveHead)
	local share = math.min(SizeConfig.clamp(size) / SizeConfig.BarLiftFullAt, 1)
	return low + (SizeConfig.BarMaxHeight - low) * share
end

function SizeConfig.battleModelScale(size: any): number
	return 1 + SizeConfig.clamp(size) * SizeConfig.BattleVisualShare / 100
end

function SizeConfig.eggScale(size: any): number
	local value = SizeConfig.clamp(size)
	local steps = SizeConfig.EggScaleSteps
	local scale = 1
	for index, step in steps do
		local stop = if steps[index + 1] then steps[index + 1].From else math.huge
		if value <= step.From then
			break
		end
		scale += (math.min(value, stop) - step.From) * step.Per
	end
	return scale
end

-- Lutas: quantos studs a mais o brainrot ocupa de cada lado na fila, pela escala do modelo na luta (0 = normal)
function SizeConfig.battleHalfWidth(scale: number): number
	return math.max(0, scale - 1) * SizeConfig.BattleHalfWidth
end

-- Quantos studs o do meio do time que segue (atrás do dono) recua pelo próprio tamanho (FollowBack)
function SizeConfig.followBack(size: any): number
	local back = SizeConfig.FollowBack
	return math.floor(SizeConfig.clamp(size) / back.Every) * back.Studs
end

-- Quanto os lugares dos lados do time que segue se afastam, pelo maior tamanho do time (1 = normal)
function SizeConfig.followSpread(largest: any): number
	local size = SizeConfig.clamp(largest)
	local extra = 0
	for _, step in SizeConfig.FollowSpread do
		if size >= step.AtLeast then
			extra = math.max(extra, step.Extra)
		end
	end
	return 1 + extra
end

-- minimum (opcional; 13/11/2026): só as faixas de minimum para cima, com as mesmas chances entre elas (ex.: 125 =
-- 42% de 125–150%, 31% de 150–175%...). A faixa onde o mínimo cai no meio é cortada nele, com a chance proporcional
-- ao pedaço que sobra (ex.: 80 = 80–100% com 4/5 da chance da faixa 75–100%; Ovo da Natureza)
function SizeConfig.rollEgg(rng: Random, minimum: number?): number
	local bands = {}
	local total = 0
	local floor = minimum or 0
	for _, candidate in SizeConfig.EggBands do
		if candidate.From >= floor then
			table.insert(bands, candidate)
			total += candidate.Chance
		elseif candidate.To > floor then
			local share = (candidate.To - floor) / (candidate.To - candidate.From)
			local cut = { Chance = candidate.Chance * share, From = math.ceil(floor), To = candidate.To }
			table.insert(bands, cut)
			total += cut.Chance
		end
	end
	if #bands == 0 then
		return SizeConfig.clamp(minimum)
	end
	local roll = rng:NextNumber() * total
	local band = bands[#bands]
	for _, candidate in bands do
		if roll < candidate.Chance then
			band = candidate
			break
		end
		roll -= candidate.Chance
	end
	-- Inteiro dentro da faixa (a última inclui o Max)
	local top = if band == bands[#bands] then band.To else band.To - 1
	return rng:NextInteger(band.From, top)
end

-- Ovos de evento/prêmio (14/11/2026, pedido do usuário: "100% aleatório, acima de 80, sem nenhum peso"): qualquer
-- inteiro de `minimum` a Max com a mesma chance (sem as faixas do EggBands)
function SizeConfig.rollEven(rng: Random, minimum: number?): number
	local floor = math.floor(SizeConfig.clamp(minimum))
	return rng:NextInteger(floor, SizeConfig.Max)
end

return SizeConfig
]=]
SOURCES["src/shared/Config/SpeciesConfig.luau"] = [=[
--[[
	SpeciesConfig — as espécies de brainrot (gerado a partir de docs/brainrots-design.md).

	Stat no nível N = (Base + Growth × (N − 1)) × (1 + bônus das estrelas: 25%, 50%, 100%) × (1 + talento %)
	Base = stats no nível 1, já com a raridade (05/11/2026, pedido do usuário: Tung Tung Tung Sahur = Vida 1600, Ataque 300,
	Velocidade 150, o MAIOR Ataque de todos; os outros na mesma proporção). 08/11/2026: Vida × 8 em todas as espécies, junto
	com o dano novo (CombatConfig.DamageMin/DamageMax). "Atk" é o Ataque.
	(conta em Shared/Brainrot/BrainrotStats). Role: Tank, Fighter, Attacker, Speedy.

	Passiva: Name e Description são o texto da tela; Effects é a regra que o motor de luta usa
	(Server/Combat/BattleEngine). Cada efeito é de um dos 15 tipos (Crit, ExtraAttack, AttackPattern,
	Stun, Burn, Debuff, Lifesteal, Dodge, DamageReduction, Reflect, Shield, HealPerTurn, AttackStacking,
	Initiative, Revive); o que cada parâmetro faz está em docs/design-etapas-6-8.md, parte 2.
	Porcentagens em fração (0.15 = 15%). O brainrot usa os Effects da espécie em brainrot.Passive
	(muda na fusão "Transferir habilidade").
]]

-- Um passo do AttackPattern (o ataque nº k usa Pattern[k])
export type PatternStep = {
	Multiplier: number?,
	Hits: number?,
	HealPercent: number?,
	StunTurns: number?,
	Crit: boolean?,
	SameTarget: boolean?, -- Hits: todos no mesmo alvo (se ele cair, os golpes acabam)
	FinalMultiplier: number?, -- Hits: multiplicador do último golpe
	Fx: string?, -- animação especial na luta (ver BattleController)
	AllTargets: boolean?, -- acerta todos os inimigos
	Debuff: { Stat: string, Percent: number, Turns: number }?, -- enfraquece cada alvo que acertou e ficou de pé
	-- Agarra (Glorbo, 13/11/2026): acertou e o alvo ficou de pé → arrasta ele na boca até o próprio lugar e cada aliado
	-- vivo faz o ataque normal do turno nele (com as habilidades que saírem); depois solta. Só na luta por turnos (Torre, Chefão, PvP); na Arena e na briga fica só o golpe
	Grab: boolean?,
}

export type Effect = {
	Type: string,
	Chance: number?,
	Multiplier: number?,
	Turns: number?,
	Percent: number?,
	Stat: string?, -- Debuff: "Atk" ou "Spd"
	AtStart: boolean?, -- Debuff: vale para todos os inimigos no início da luta
	Before: boolean?, -- ExtraAttack: antes do ataque principal
	AllTargets: boolean?, -- ExtraAttack: acerta todos os inimigos
	Fx: string?, -- ExtraAttack: animação especial na luta (ver BattleController)
	Pattern: { PatternStep }?,
	Repeat: boolean?,
	CounterPercent: number?, -- Dodge: contra-ataque com essa fração do Ataque
	NextAttackBonus: number?, -- Dodge: bônus no próximo ataque principal depois de esquivar
	Miss: boolean?, -- Dodge: a tela mostra "ERROU!" em vez de "ESQUIVOU!"
	SpeedBonus: number?,
	PerTurn: number?,
	Max: number?,
	Uses: number?,
	Every: number?, -- TeamHeal e TimeStop: a cada quantos ataques
	Actions: number?, -- TimeStop: golpes com o tempo parado
	Threshold: number?, -- Execute: fração da Vida do alvo
	Chain: number?, -- ExtraAttack: máximo de extras seguidos no turno
	BreakDamage: number?, -- (sem uso desde 16/11/2026)
	BreakHpDamage: number?, -- Shield: fração da Vida máxima de quem tinha o escudo, quando ele estoura
	Vulnerable: number?, -- Stun: dano extra recebido enquanto atordoado
	Fury: number?, -- Revive: +Ataque ao voltar
	Recharges: number?, -- FirstDodge: quantas vezes um crítico recarrega a esquiva na mesma luta
	Limit: number?, -- DodgeRiposte: revides por luta (16/11/2026)
	SuperBossShare: number?, -- DodgeRiposte: fração do dano do revide contra Super chefe (18/11/2026)
	ArenaFreeze: number?, -- DodgeRiposte: na Arena, segundos em que quem levou o revide fica congelado (18/11/2026)
	StunTurns: number?, -- DodgeRiposte/FirstHitGuard: turnos de atordoamento em quem levou o revide
	OwnMaxHp: boolean?, -- TeamShield/TeamShieldEvery: escudo pela Vida máxima de CADA aliado (sem isto: a de quem usa)
	-- LowHpRush (Pot Hotspot): Thresholds = marcas de Vida (StarThresholds = as marcas com 1, 2 e 3 estrelas);
	-- HurtCharge (Ballerina): Multiplier no próximo ataque
	Thresholds: { number }?,
	StarThresholds: { { number } }?,
	-- Soma por estrela num número que não cresce com os +50% (PassivePower; Cappuccino: { Recharges = 1 } = +1 recarga por ★)
	StarAdd: { [string]: number }?,
	NoShieldMultiplier: number?, -- ShieldHunter: dano em quem está sem escudo
	ShieldMultiplier: number?, -- ShieldHunter: dano em quem tem escudo
}

export type Species = {
	Id: string,
	Name: string,
	Rarity: string,
	Role: string,
	Description: string,
	Base: { Hp: number, Atk: number, Spd: number },
	Growth: { Hp: number, Atk: number, Spd: number },
	-- ArenaDescription: o texto da "Versão da arena" na mochila (13/11/2026; turnos viram segundos, PassiveText)
	Passive: { Name: string, Description: string, ArenaDescription: string?, Fx: string?, Effects: { Effect } },
	Shout: string,
}

local LIST: { Species } = {
	{
		Id = "BlueberriniOctopussini",
		Name = "Blueberrini Octopussini",
		Rarity = "Epic", -- 18/11/2026 (pedido do usuário): era Comum
		Role = "Fighter",
		Description = "Polvo-mirtilo que vive no fundo do mar entre corais e bolhas, e mancha tudo de roxo.",
		-- 18/11/2026 (pedido do usuário; média dos Épicos: Vida 792, Ataque 68, Velocidade 76): Vida 150%, Ataque ~80%
		-- (baixo), Velocidade 50%; o crescimento por nível na mesma proporção. Era Vida 360, Ataque 40, Velocidade 25
		Base = { Hp = 1190, Atk = 55, Spd = 38 },
		Growth = { Hp = 14.7, Atk = 5.3, Spd = 2.3 },
		Passive = {
			Name = "Tentáculos",
			-- 18/11/2026 (pedido do usuário): habilidade nova (era 15% de chance de prender por 1 turno, +15% de dano
			-- preso). FirstHitGuard: BattleEngine (strike, 6b) e BrawlSkills; o revide toca o "spell" (BlockAnimConfig
			-- Counter). StunTurns não cresce com estrela (PassivePower); a redução também não, só o revide
			Description = "Começa a partida com {1.Percent} de redução de dano até levar o primeiro golpe.\n\nO primeiro golpe que levar na partida, revida com {1.Multiplier} do seu ataque e atordoa o atacante por {1.StunTurns} turnos.",
			ArenaDescription = "Começa a partida com {1.Percent} de redução de dano até levar o primeiro golpe.\n\nO primeiro golpe que levar na partida, revida com {1.Multiplier} do seu ataque e atordoa o atacante por {1.StunTurns:s}.",
			-- Sem Fx (18/11/2026, pedido do usuário: o "Ink" roxo era feio); só a animação "spell" no revide
			Effects = {
				-- ArenaFreeze (18/11/2026): na Arena quem bateu fica congelado o tempo do "spell" (0,6 s), como no parry do
				-- Cappuccino, e depois leva o atordoamento
				{ Type = "FirstHitGuard", Percent = 0.5, Multiplier = 1, StunTurns = 2, ArenaFreeze = 0.6 },
			},
		},
		Shout = "Blueberrini octopussini!",
	},
	{
		Id = "GraipussiMedussi",
		Name = "Graipussi Medussi",
		Rarity = "Common",
		Role = "Speedy",
		Description = "Água-viva feita de um cacho de uvas que dá choquinho em quem tenta comer uma.",
		Base = { Hp = 280, Atk = 40, Spd = 40 },
		Growth = { Hp = 3.6, Atk = 3.7, Spd = 2 },
		Passive = {
			Name = "Choque de Uva",
			Description = "{1.Chance} de chance de dar um choque que atordoa o inimigo.",
			ArenaDescription = "{1.Chance} de chance de atordoar o alvo por {1.Turns:s}.",
			Fx = "Zap",
			Effects = {
				{ Type = "Stun", Chance = 0.15, Turns = 1 },
			},
		},
		Shout = "Graipussi medussi!",
	},
	{
		Id = "ZibraZubraZibralini",
		Name = "Zibra Zubra Zibralini",
		Rarity = "Common",
		Role = "Speedy",
		Description = "Zebra com corpo de melancia que galopa pela savana espalhando sementes.",
		Base = { Hp = 280, Atk = 40, Spd = 40 },
		Growth = { Hp = 3.5, Atk = 3.9, Spd = 1.9 },
		Passive = {
			Name = "Galope",
			Description = "{1.Chance} de chance de esquivar. Depois de esquivar, o próximo golpe dá +{1.NextAttackBonus}.",
			Fx = "Gallop",
			Effects = {
				{ Type = "Dodge", Chance = 0.15, NextAttackBonus = 0.2 },
			},
		},
		Shout = "Zibra zubra zibralini!",
	},
	{
		Id = "PenguinoCocosino",
		Name = "Penguino Cocosino",
		Rarity = "Common",
		Role = "Tank",
		Description = "Pinguim que se mudou para dentro de um coco para fugir do frio e agora reclama do calor.",
		Base = { Hp = 440, Atk = 35, Spd = 20 },
		Growth = { Hp = 5.6, Atk = 3.3, Spd = 0.8 },
		Passive = {
			Name = "Casca Dura",
			Description = "Recebe {1.Percent} menos dano.",
			Fx = "Shell",
			Effects = {
				{ Type = "DamageReduction", Percent = 0.1 },
			},
		},
		Shout = "Penguino cocosino!",
	},
	{
		Id = "BobriniCococosini",
		Name = "Bobrini Cococosini",
		Rarity = "Common",
		Role = "Tank",
		Description = "Castor que roeu um coco por dentro e decidiu morar lá mesmo.",
		Base = { Hp = 480, Atk = 35, Spd = 20 },
		Growth = { Hp = 6, Atk = 3.4, Spd = 0.8 },
		Passive = {
			Name = "Dentes de Castor",
			-- 18/11/2026 (pedido do usuário): sem multiplicador próprio (crescia com as estrelas); usa o crítico normal
			Description = "{1.Chance} de chance de crítico com uma mordida.",
			Fx = "Bite",
			Effects = {
				{ Type = "Crit", Chance = 0.2 },
			},
		},
		Shout = "Bobrini cococosini!",
	},
	{
		Id = "TracotucotuluDelapeladustuz",
		Name = "Tracotucotulu Delapeladustuz",
		Rarity = "Common",
		Role = "Speedy",
		Description = "Camelo fundido com um fusquinha que atravessa o deserto buzinando sem parar.",
		Base = { Hp = 280, Atk = 40, Spd = 40 },
		Growth = { Hp = 3.6, Atk = 3.7, Spd = 1.9 },
		Passive = {
			Name = "Arrancada",
			-- 16/11/2026 (pedido do usuário): liga no começo da luta (joga primeiro), não no 1º turno dele
			Description = "No começo da luta, sai na frente e ganha +{1.SpeedBonus} de Velocidade por {1.Turns} turnos.",
			ArenaDescription = "No começo da luta, sai na frente e ganha +{1.SpeedBonus} de Velocidade por {1.Turns:s}.",
			Fx = "Dash",
			Effects = {
				{ Type = "Initiative", Turns = 2, SpeedBonus = 0.3, AtStart = true },
			},
		},
		Shout = "Tracotucotulu!",
	},
	{
		Id = "PotHotspot",
		Name = "Pot Hotspot",
		Rarity = "Common",
		Role = "Attacker",
		Description = "Esqueleto chorão que implora por um roteador de internet com o celular sem sinal na mão.",
		Base = { Hp = 320, Atk = 60, Spd = 25 },
		Growth = { Hp = 3.5, Atk = 5.7, Spd = 1.3 },
		Passive = {
			Name = "Sem Sinal",
			-- 13/11/2026 (pedido do usuário): era 15% dos golpes errarem com revide de 0.25x
			Description = "Quando a Vida dele cai abaixo de {1.Thresholds}, o próximo turno é dele (uma vez em cada marca).",
			ArenaDescription = "Quando a Vida dele cai abaixo de {1.Thresholds}, ataca na hora (uma vez em cada marca).",
			Fx = "Glitch",
			Effects = {
				-- Melhoria própria por estrela (pedido do usuário, no lugar dos +50%): mais marcas de Vida (PassivePower)
				{
					Type = "LowHpRush",
					Thresholds = { 0.5 },
					StarThresholds = { { 0.33, 0.66 }, { 0.25, 0.5, 0.75 }, { 0.2, 0.4, 0.6, 0.8 } },
				},
			},
		},
		Shout = "Hotspot, bro!",
	},
	{
		Id = "BrrEsTehPatipum",
		Name = "Brr Es Teh Patipum",
		Rarity = "Common",
		Role = "Fighter",
		Description = "Copo de chá gelado com pés gigantes descalços que pisa em quem pede sem açúcar.",
		Base = { Hp = 360, Atk = 40, Spd = 25 },
		Growth = { Hp = 4.3, Atk = 4.2, Spd = 1.4 },
		Passive = {
			Name = "Gelo no Copo",
			Description = "{1.Chance} de chance de deixar o inimigo {1.Percent} mais lento por {1.Turns} turnos.",
			ArenaDescription = "{1.Chance} de chance de deixar o alvo {1.Percent} mais lento por {1.Turns:s}.",
			Fx = "Ice",
			Effects = {
				-- 12/11/2026: era até o fim da luta (Turns = 0); nada dura para sempre (CombatConfig.MinDebuffTurns)
				{ Type = "Debuff", Stat = "Spd", Chance = 0.2, Percent = 0.2, Turns = 2 },
			},
		},
		Shout = "Brr es teh patipum!",
	},
	{
		Id = "Pakrahmatmamat",
		Name = "Pakrahmatmamat",
		Rarity = "Common",
		Role = "Attacker",
		Description = "Lápis com pés humanos que corrige a prova de todo mundo, menos a dele.",
		Base = { Hp = 280, Atk = 50, Spd = 25 },
		Growth = { Hp = 3.4, Atk = 5.2, Spd = 1.3 },
		Passive = {
			Name = "Ponta Afiada",
			-- 18/11/2026 (pedido do usuário): sem multiplicador próprio (crescia com as estrelas); usa o crítico normal
			Description = "{1.Chance} de chance de crítico.",
			Fx = "Pierce",
			Effects = {
				{ Type = "Crit", Chance = 0.15 },
			},
		},
		Shout = "Pakrahmatmamat!",
	},
	{
		Id = "TaTaTaSahur",
		Name = "Ta Ta Ta Sahur",
		Rarity = "Common",
		Role = "Fighter",
		Description = "Bule de chá de pernas compridas e olhos azuis arregalados que acorda a vizinhança apitando.",
		Base = { Hp = 360, Atk = 40, Spd = 25 },
		Growth = { Hp = 4.6, Atk = 4.2, Spd = 1.4 },
		Passive = {
			Name = "Apito do Sahur",
			-- 13/11/2026: o texto antigo ("a cada 5 ataques") escondia que o 1º ataque já apita
			Description = "No 1º ataque e depois a cada {1.Pattern#}, apita e atordoa o alvo: ele perde o próximo turno.",
			ArenaDescription = "No 1º ataque e depois a cada {1.Pattern#}, apita e atordoa o alvo por {1.Pattern.1.StunTurns:s}.",
			Fx = "Whistle",
			Effects = {
				{ Type = "AttackPattern", Repeat = true, Pattern = { { StunTurns = 1 }, {}, {}, {}, {} } },
			},
		},
		Shout = "Ta ta ta... sahur!",
	},
	{
		Id = "OrangutiniAnanassini",
		Name = "Orangutini Ananassini",
		Rarity = "Uncommon",
		Role = "Fighter",
		Description = "Orangotango com corpo de abacaxi que se recusa a entrar em qualquer salada de frutas.",
		Base = { Hp = 480, Atk = 55, Spd = 35 },
		Growth = { Hp = 5.8, Atk = 5.3, Spd = 1.8 },
		Passive = {
			Name = "Coroa de Folhas",
			Description = "Recebe {1.Percent} menos dano e devolve {2.Percent} do dano que leva.",
			-- Espinhos: o efeito é o mesmo para todos (Client/UI/ThornBurst, branco); o verde "Thorns" saiu (07/11/2026)
			Effects = {
				{ Type = "DamageReduction", Percent = 0.1 },
				{ Type = "Reflect", Percent = 0.12 },
			},
		},
		Shout = "Orangutini ananassini!",
	},
	{
		Id = "EspressonaSignora",
		Name = "Espressona Signora",
		Rarity = "Uncommon",
		Role = "Attacker",
		Description = "A versão de preto da Ballerina Cappuccina: uma dama com xícara de espresso na cabeça, amarga e elegante.",
		Base = { Hp = 400, Atk = 70, Spd = 35 },
		Growth = { Hp = 4.6, Atk = 7.3, Spd = 1.7 },
		Passive = {
			Name = "Dose Dupla",
			Description = "{1.Chance} de chance de bater de novo, até {1.Chain} vezes seguidas.",
			Fx = "Coffee",
			Effects = {
				{ Type = "ExtraAttack", Chance = 0.15, Chain = 2 },
			},
		},
		Shout = "Espressona, signora!",
	},
	{
		Id = "BallerinoLololo",
		Name = "Ballerino Lololo",
		Rarity = "Uncommon",
		Role = "Tank",
		Description = "Copo de frappé marombeiro de tutu e sapatilha que dança balé levantando peso.",
		Base = { Hp = 700, Atk = 80, Spd = 10 }, -- 13/11/2026 (pedido do usuário): era 600/45/25
		Growth = { Hp = 7.3, Atk = 4.3, Spd = 1.1 },
		Passive = {
			Name = "Músculo de Frappé",
			Description = "No começo da luta, ganha escudo de {1.Percent} da Vida. Quando quebra, explode em quem quebrou com dano de {1.BreakHpDamage} da sua Vida máxima.",
			Fx = "ShieldPop",
			Effects = {
				{ Type = "Shield", Percent = 0.15, BreakHpDamage = 0.1 }, -- 16/11/2026: era BreakDamage 0.5 (× Ataque)
			},
		},
		Shout = "Ballerino lololo!",
	},
	{
		Id = "BrriBrriBicusDicusBombicus",
		Name = "Brri Brri Bicus Dicus Bombicus",
		Rarity = "Uncommon",
		Role = "Fighter",
		Description = "Passarinho legionário romano de capacete, capa e espada que se acha o imperador do galinheiro.",
		Base = { Hp = 480, Atk = 55, Spd = 35 },
		Growth = { Hp = 6, Atk = 5.6, Spd = 1.7 },
		Passive = {
			Name = "Escudo Romano",
			Description = "{1.Chance} de chance de bloquear {1.Percent} de um golpe.",
			Fx = "Block",
			Effects = {
				{ Type = "DamageReduction", Chance = 0.2, Percent = 0.5 },
			},
		},
		Shout = "Brri brri bicus dicus!",
	},
	{
		Id = "OrcaleroOrcala",
		Name = "Orcalero Orcala",
		Rarity = "Uncommon",
		Role = "Speedy",
		Description = "Orca de três pernas e tênis branco que jura que não copiou o primo tubarão.",
		Base = { Hp = 360, Atk = 50, Spd = 50 },
		Growth = { Hp = 4.7, Atk = 4.9, Spd = 2.5 },
		Passive = {
			Name = "Onda",
			Description = "No 1º ataque e depois a cada {1.Every} ataques, em vez de bater, solta uma onda que acerta TODOS os inimigos com {1.Multiplier} do seu ataque.",
			ArenaDescription = "No 1º ataque e depois a cada {1.Every}, em vez de bater, solta uma onda em todos os inimigos perto com {1.Multiplier} do seu ataque.",
			Effects = {
				-- 13/11/2026 (pedido do usuário): era 15% de chance e 0.6x; depois 1x, agora 0.5x
				{ Type = "ExtraAttack", Every = 3, Multiplier = 0.5, AllTargets = true, Fx = "Wave" },
			},
		},
		Shout = "Orcalero orcalà!",
	},
	{
		Id = "SpioniroGolubiro",
		Name = "Spioniro Golubiro",
		Rarity = "Uncommon",
		Role = "Speedy",
		Description = "Pombo espião croata de sobretudo e óculos escuros que fotografa tudo o que você faz.",
		Base = { Hp = 360, Atk = 50, Spd = 50 },
		Growth = { Hp = 4.6, Atk = 5.1, Spd = 2.4 },
		Passive = {
			Name = "Dossiê",
			Description = "O 1º golpe é crítico garantido, com {1.Pattern.1.Multiplier} do seu ataque.",
			Fx = "Scan",
			Effects = {
				{ Type = "AttackPattern", Repeat = false, Pattern = { { Multiplier = 2, Crit = true } } },
			},
		},
		Shout = "Spioniro golubiro!",
	},
	{
		Id = "GangsterFootera",
		Name = "Gangster Footera",
		Rarity = "Uncommon",
		Role = "Attacker",
		Description = "Um pé de chulé lendário vestido de chefão da máfia, com corrente de ouro e óculos aviador.",
		Base = { Hp = 400, Atk = 70, Spd = 35 },
		Growth = { Hp = 4.5, Atk = 7.1, Spd = 1.8 },
		Passive = {
			Name = "Chulé Mafioso",
			Description = "{1.Chance} de chance de deixar o inimigo tonto (−{1.Percent} de Ataque por {1.Turns} turnos).",
			ArenaDescription = "{1.Chance} de chance de tirar {1.Percent} do Ataque do alvo por {1.Turns:s}.",
			Fx = "Stink",
			Effects = {
				{ Type = "Debuff", Stat = "Atk", Chance = 0.2, Percent = 0.2, Turns = 2 },
			},
		},
		Shout = "Footera!",
	},
	{
		Id = "Garamararamararaman",
		Name = "Garamararamararaman dan Madudungdung tak tuntung perkuntung",
		Rarity = "Uncommon",
		Role = "Fighter",
		Description = "Um saleiro e um pote de mel de pernas cabeludas que nunca se separam, nem para lutar.",
		Base = { Hp = 440, Atk = 55, Spd = 35 },
		Growth = { Hp = 5.5, Atk = 5.2, Spd = 1.7 },
		Passive = {
			Name = "Doce e Salgado",
			Description = "Alterna: um golpe cura {1.Pattern.1.HealPercent} da Vida dele, o seguinte dá {1.Pattern.2.Multiplier} do seu ataque.",
			Fx = "SweetSalty",
			Effects = {
				{ Type = "AttackPattern", Repeat = true, Pattern = { { HealPercent = 0.06 }, { Multiplier = 1.25 } } },
			},
		},
		Shout = "Garamararam... madudungdung!",
	},
	{
		Id = "BananitaDolphinita",
		Name = "Bananita Dolphinita",
		Rarity = "Rare",
		Role = "Speedy",
		Description = "Golfinho de banana que salta tão alto que esquece de descascar no caminho.",
		Base = { Hp = 480, Atk = 65, Spd = 65 },
		Growth = { Hp = 6.2, Atk = 6.5, Spd = 3.2 },
		Passive = {
			Name = "Salto",
			Description = "{1.Chance} de chance de esquivar e revidar com {1.CounterPercent} do seu ataque.",
			Fx = "Splash",
			Effects = {
				{ Type = "Dodge", Chance = 0.15, CounterPercent = 0.6 },
			},
		},
		Shout = "Bananita dolphinita!",
	},
	{
		Id = "BurbaloniLuliloli",
		Name = "Burbaloni Luliloli",
		-- 19/11/2026 (pedido do usuário): Mítico, Vida 1700, Ataque 80, Velocidade 100 (era Raro 800/55/30)
		Rarity = "Mythic",
		Role = "Tank",
		Description = "Capivara que mora dentro de um coco e não sai de lá nem para resolver os próprios problemas.",
		Base = { Hp = 1700, Atk = 80, Spd = 100 },
		Growth = { Hp = 9.9, Atk = 5.6, Spd = 1.4 },
		-- 19/11/2026 (pedido do usuário, modelo novo dele): a cada 4º turno se enfia no coco por 2 turnos, sem atacar, com
		-- 60% de redução de dano e 20% de espinhos (BattleEngine shellTurn; a redução cresce com as estrelas até o teto
		-- CombatConfig.PassiveMaxReduction, e o texto já mostra o valor com o teto). Era 15% de redução sempre
		Passive = {
			Name = "Casca de Coco",
			-- 19/11/2026 (mais tarde, pedido do usuário): entra depois de Every golpes dados OU levados (era a cada 4º turno)
			Description = "Depois de {1.Every} golpes, dados ou levados, se enfia no coco até levar {1.Turns} ataques: recebe {1.Percent} menos dano e devolve {1.Thorns} do dano, mas não ataca.",
			Fx = "CocoShell",
			Effects = {
				{ Type = "CocoShell", Every = 3, Turns = 2, Percent = 0.3, Thorns = 0.2 }, -- Every 3 desde 19/11/2026 (era 2); Turns = ataques levados para sair; Percent 0.3 (era 0.6) (19/11/2026)
			},
		},
		Shout = "Burbaloni luliloli!",
	},
	{
		Id = "IlCactoHipopotamo",
		Name = "Il Cacto Hipopotamo",
		Rarity = "Rare",
		Role = "Tank",
		Description = "Cacto gigante com cabeça de hipopótamo muito sério, de sandálias brilhantes enormes.",
		Base = { Hp = 760, Atk = 55, Spd = 30 },
		Growth = { Hp = 9.7, Atk = 5.8, Spd = 1.4 },
		Passive = {
			Name = "Espinhos",
			Description = "Devolve {1.Percent} do dano que leva.",
			-- Espinhos: o efeito é o mesmo para todos (Client/UI/ThornBurst, branco); o verde "Thorns" saiu (07/11/2026)
			Effects = {
				{ Type = "Reflect", Percent = 0.15 },
			},
		},
		Shout = "Il cacto hipopotamo!",
	},
	{
		Id = "GiraffaCeleste",
		Name = "Giraffa Celeste",
		-- 17/11/2026 (pedido do usuário): Épica (era Rara). Os 3 stats (base e crescimento) × 1,295 para o Poder chegar no
		-- do Glorbo Épico (~2.026; era 1.375) e depois metade do Ataque foi para a Velocidade. Era Base 600/70/45 e
		-- Growth 7,3/7/2,4; × 1,295 = 777/91/58 e 9,45/9,1/3,1. A habilidade era 15% de bater duas vezes e 8% de esquiva
		Rarity = "Epic",
		Role = "Fighter",
		Description = "Girafa-melancia astronauta de botas, sempre voltando de uma viagem pelo espaço.",
		Base = { Hp = 777, Atk = 45, Spd = 104 },
		Growth = { Hp = 9.45, Atk = 4.55, Spd = 7.65 },
		Passive = {
			Name = "Gravidade Zero",
			Description = "No começo de cada turno dela, cura o aliado mais ferido em {1.Percent} da Vida máxima dela. Não cura a si mesma.",
			ArenaDescription = "A cada {turn}, cura o aliado mais ferido em {1.Percent} da Vida máxima dela. Não cura a si mesma.",
			Fx = "StarHeal", -- era "Float" ("FLUTUOU!", da esquiva antiga)
			Effects = {
				-- Engine: começo do turno (BattleEngine, BrawlSkills); a Vida curada conta para ela na tabela de dano
				{ Type = "TurnHealAlly", Percent = 0.15 },
			},
		},
		Shout = "Giraffa celeste!",
	},
	{
		Id = "CocofantoElefanto",
		Name = "Cocofanto Elefanto",
		Rarity = "Rare",
		Role = "Tank",
		Description = "Filhote de elefante com corpo de coco cabeludo que pinga leite de coco quando se emociona.",
		Base = { Hp = 800, Atk = 55, Spd = 30 },
		Growth = { Hp = 10.2, Atk = 5.8, Spd = 1.3 },
		Passive = {
			Name = "Água de Coco",
			Description = "Cura {1.Percent} da Vida por turno.",
			ArenaDescription = "Cura {1.Percent} da Vida a cada {turn}.",
			Fx = "Coconut",
			Effects = {
				{ Type = "HealPerTurn", Percent = 0.04 },
			},
		},
		Shout = "Cocofanto elefanto!",
	},
	{
		Id = "RhinoToasterino",
		Name = "Rhino Toasterino",
		Rarity = "Rare",
		Role = "Attacker",
		Description = "Rinoceronte-torradeira sorridente que serve torrada quentinha antes de dar a chifrada.",
		Base = { Hp = 520, Atk = 95, Spd = 45 },
		Growth = { Hp = 6.2, Atk = 9.2, Spd = 2.4 },
		Passive = {
			Name = "Torrada Quente",
			Description = "{1.Chance} de chance de queimar o inimigo ({1.Percent} da Vida dele por {1.Turns} turnos).",
			ArenaDescription = "{1.Chance} de chance de queimar o alvo: ele perde {1.Percent} da Vida a cada {turn}, por {1.Turns:s}.",
			Fx = "Fire",
			Effects = {
				{ Type = "Burn", Chance = 0.25, Percent = 0.05, Turns = 2 },
			},
		},
		Shout = "Rhino toasterino!",
	},
	{
		Id = "BobritoBandito",
		Name = "Bobrito Bandito",
		-- 15/11/2026 (pedido do usuário): Lendário (era Raro). Os 3 stats (base e crescimento) × 1,67, a mesma % em todos,
		-- para o Poder √(Vida×Ataque×Vel) chegar no dos Lendários (~3.300; era 1.530). Era Base 520/100/45 e
		-- Growth 6/9,6/2,2. A habilidade era 25% de chance de bater duas vezes
		Rarity = "Legendary",
		Role = "Attacker",
		Description = "Castor gângster de sobretudo e chapéu que comanda a máfia dos brainrots com uma metralhadora de brinquedo.",
		-- 15/11/2026 (pedido do usuário): Velocidade 75 → 140, Ataque igual e a Vida 870 → 466 para o Poder ficar o mesmo
		-- (√(466×167×140) ≈ 3.301). Depois (pedido do usuário): Ataque 167 → 145 e a Vida 466 → 537 para o mesmo Poder
		-- (√(537×145×140) ≈ 3.302). Growth na mesma proporção (era Hp 10, Atk 16, Spd 3,7)
		Base = { Hp = 537, Atk = 145, Spd = 140 },
		Growth = { Hp = 6.2, Atk = 13.9, Spd = 6.9 },
		Passive = {
			Name = "Rajada",
			Description = "A cada 2 ataques, o próximo é uma rajada de {1.Pattern.3.Hits} balas no inimigo da frente, cada uma com {1.Pattern.3.Multiplier} do seu ataque.",
			ArenaDescription = "A cada 2 golpes, o próximo é uma rajada de {1.Pattern.3.Hits} balas no alvo, cada uma com {1.Pattern.3.Multiplier} do seu ataque.",
			Fx = "Burst",
			Effects = {
				-- 2 ataques normais e o 3º é a rajada: 5 balas de 0,4x (se o da frente cair, as balas seguem no próximo)
				{
					Type = "AttackPattern",
					Repeat = true,
					Pattern = { {}, {}, { Hits = 5, Multiplier = 0.4, Fx = "Burst" } },
				},
			},
		},
		Shout = "Bobrito bandito!",
	},
	{
		Id = "LaVacaSaturnoSaturnita",
		Name = "La Vaca Saturno Saturnita",
		Rarity = "Epic",
		Role = "Tank",
		Description = "Vaca-planeta com anel de Saturno e pernas humanas, que passeia pelo espaço como se fosse um pasto.",
		Base = { Hp = 1000, Atk = 75, Spd = 40 },
		Growth = { Hp = 12.4, Atk = 7.4, Spd = 1.8 },
		Passive = {
			Name = "Gravidade",
			Description = "Os inimigos começam a luta {1.Percent} mais lentos por {1.Turns} turnos (os anéis puxam todo mundo).",
			ArenaDescription = "Os inimigos da sua linha começam a luta {1.Percent} mais lentos por {1.Turns:s}.",
			Fx = "Gravity",
			Effects = {
				-- 12/11/2026: era até o fim da luta (Turns = 0); nada dura para sempre (CombatConfig.MinDebuffTurns)
				{ Type = "Debuff", Stat = "Spd", Percent = 0.25, Turns = 3, AtStart = true },
			},
		},
		Shout = "Muuu... Saturnita!",
	},
	{
		Id = "BombombiniGusini",
		Name = "Bombombini Gusini",
		-- 15/11/2026 (pedido do usuário): Mítico (era Épico). Os 3 stats (base e crescimento) × 1,764, a mesma % em todos,
		-- para o Poder chegar no dos Míticos (~4.730; era 2.020). Era Base 600/85/80 e Growth 7,5/7,9/4. A habilidade era
		-- o 1º ataque em todos os inimigos com 1,3x o dano
		Rarity = "Mythic",
		Role = "Speedy",
		Description = "Ganso que virou caça a jato e grasna mais alto que a própria turbina.",
		Base = { Hp = 1060, Atk = 150, Spd = 141 },
		Growth = { Hp = 13.2, Atk = 13.9, Spd = 7.1 },
		Passive = {
			Name = "Napalm",
			Description = "Antes de todos agirem, voa por cima do inimigo com menos Vida e solta um napalm nele: {1.Multiplier} do seu ataque. Ao cair, explode em quem o derrubou: {2.Multiplier} do seu ataque.",
			ArenaDescription = "No começo da luta, solta um napalm no inimigo com menos Vida: {1.Multiplier} do seu ataque. Ao cair, explode em quem o derrubou: {2.Multiplier} do seu ataque.",
			Fx = "Napalm",
			Effects = {
				-- Engine: openingSnipes (BattleEngine). Dois com isso na luta: o mais rápido solta primeiro
				{ Type = "OpeningSnipe", Multiplier = 2.5, Fx = "Napalm" },
				-- 15/11/2026 (pedido do usuário): segunda habilidade. Engine: checkDown (BattleEngine), evento "DeathBlast"
				{ Type = "DeathBlast", Multiplier = 2 },
			},
		},
		Shout = "Bombombini gusini!",
	},
	{
		Id = "OdinDinDinDun",
		Name = "Odin Din Din Dun",
		-- 14/11/2026 (pedido do usuário): Lendário (era Épico). Os 3 stats (base e crescimento) × 1,308, a mesma % em
		-- todos (a distribuição não muda), para o Poder √(Vida×Ataque×Vel) chegar no dos Lendários (~3.310; era 2.213).
		-- Era Base 680/120/60 e Growth 7,9/11,6/3,1
		Rarity = "Legendary",
		Role = "Attacker",
		Description = "Laranja marombeira que vive flexionando os bíceps, também conhecida como Udin Din Din Dun.",
		Base = { Hp = 890, Atk = 157, Spd = 78 },
		Growth = { Hp = 10.3, Atk = 15.2, Spd = 4.1 },
		Passive = {
			Name = "Suco de Ataque",
			Description = "+{1.PerTurn} de Ataque a cada turno (até +{1.Max}).",
			ArenaDescription = "Ganha +{1.PerTurn} de Ataque a cada {turn}, até +{1.Max}.",
			Fx = "Rage",
			Effects = {
				-- 14/11/2026 (pedido do usuário): +2% por turno (era 0,08); o teto continua em 6 turnos (era 0,48)
				{ Type = "AttackStacking", PerTurn = 0.10, Max = 0.60 },
			},
		},
		Shout = "Odin din din dun!",
	},
	{
		Id = "GlorboFruttodrillo",
		Name = "Glorbo Fruttodrillo",
		-- 17/11/2026 (pedido do usuário): Lendário (era Épico). Os 3 stats (base e crescimento) × 1,384, a mesma % em todos,
		-- para o Poder chegar no dos Lendários (~3.300; era 2.026). Era Base 760/90/60 e Growth 9,7/9,4/2,9
		Rarity = "Legendary",
		Role = "Fighter",
		Description = "Crocodilo com corpo de melancia que anda pelo pântano oferecendo fatia a quem passa.",
		Base = { Hp = 1052, Atk = 125, Spd = 83 },
		Growth = { Hp = 13.4, Atk = 13, Spd = 4 },
		-- 13/11/2026 (pedido do usuário): era roubo de vida de 25%. Agora o 3º ataque é uma mordida que agarra o alvo
		Passive = {
			Name = "Mordida Suculenta",
			Description = "A cada {1.Pattern#} ataques, morde com {1.Pattern.3.Multiplier} do seu ataque, atordoa por {1.Pattern.3.StunTurns} turno e puxa o alvo para o time: cada aliado dá um ataque nele.",
			ArenaDescription = "A cada {1.Pattern#} ataques, morde com {1.Pattern.3.Multiplier} do seu ataque e atordoa por {1.Pattern.3.StunTurns:s}.",
			Fx = "Chomp",
			Effects = {
				{
					Type = "AttackPattern",
					Repeat = true,
					Pattern = { {}, {}, { Multiplier = 0.75, StunTurns = 1, Grab = true } },
				},
			},
		},
		Shout = "Glorbo fruttodrillo!",
	},
	{
		Id = "TrulimeroTrulichina",
		Name = "Trulimero Trulichina",
		Rarity = "Epic",
		Role = "Speedy",
		Description = "Peixe prateado com cabeça de gato e quatro pernas humanas que passeia pela praia como se fosse normal.",
		Base = { Hp = 600, Atk = 85, Spd = 85 },
		Growth = { Hp = 7.6, Atk = 8.1, Spd = 4.3 },
		-- 14/11/2026 (pedido do usuário): cura 30% da Vida a cada 3 ataques dele (era esquiva de 20% + 25% no golpe seguinte)
		Passive = {
			Name = "Nadadeiras Rápidas",
			Description = "Cura {1.Percent} da Vida a cada {1.Every} ataques.",
			Fx = "FishHeal",
			Effects = {
				{ Type = "HealEveryHits", Percent = 0.3, Every = 3, Dealt = true },
			},
		},
		Shout = "Trulimero trulichina!",
	},
	{
		Id = "BrrBrrPatapim",
		Name = "Brr Brr Patapim",
		Rarity = "Secret", -- só no Ovo da Natureza (chefão do Coliseu)
		Role = "Tank",
		Description = "Macaco-árvore narigudo de pés gigantes, com um chapéu dourado onde o sapinho Slim se esconde.",
		Base = { Hp = 2840, Atk = 160, Spd = 120 }, -- Ataque 210 → 160 em 15/11/2026 (pedido do usuário)
		Growth = { Hp = 35.4, Atk = 20.8, Spd = 5 },
		Passive = {
			Name = "Raízes Fundas",
			Description = "Recebe {1.Percent} menos dano e quem bate nele com ataque básico fica {2.Percent} mais lento por {2.Turns} turno.",
			ArenaDescription = "Recebe {1.Percent} menos dano. Quem bate nele com ataque básico fica {2.Percent} mais lento por {2.Turns:s}.",
			Fx = "Roots",
			Effects = {
				-- 13/11/2026 (pedido do usuário): a cura de 3% por turno saiu; lentidão por ataque; prender 10% → 25%
				-- 14/11/2026 (pedido do usuário): o prender (Trap, 25% de quem bate nele perder o turno) saiu
				{ Type = "DamageReduction", Percent = 0.2 },
				-- 14/11/2026 (pedido do usuário): a lentidão era dele atacando; agora é em quem bate nele com ataque básico
				-- (habilidade não conta; RetaliateDebuff no BattleEngine e no BrawlSkills)
				{ Type = "RetaliateDebuff", Stat = "Spd", Percent = 0.25, Turns = 1, Chance = 1 },
			},
		},
		Shout = "Brr brr patapim!",
	},
	{
		Id = "LiriliLarila",
		Name = "Lirilì Larilà",
		Rarity = "Mythic", -- 13/11/2026 (pedido do usuário): era Lendário, stats subiram junto
		Role = "Fighter",
		Description = "Elefante-cacto de sandália que anda pelo deserto acompanhado de um despertador que flutua.",
		Base = { Hp = 1600, Atk = 130, Spd = 105 }, -- 13/11/2026: era 1080/125/80 (Lendário), depois 1400/145
		Growth = { Hp = 13.6, Atk = 12.5, Spd = 4.2 },
		Passive = {
			Name = "Za Warudo",
			Description = "No 1º ataque e depois a cada {1.Every}, em vez de bater, para o tempo e dá {1.Actions} golpes de {1.Multiplier} do seu ataque em TODOS os inimigos.",
			ArenaDescription = "No 1º ataque e depois a cada {1.Every}, em vez de bater, para o tempo e dá {1.Actions} golpes de {1.Multiplier} do seu ataque em TODOS os inimigos da Arena.",
			Fx = "TimeStop",
			Effects = {
				-- 13/11/2026 (pedido do usuário): era 2 golpes de 0.75x num alvo só
				{ Type = "TimeStop", Multiplier = 0.5, Every = 5, Actions = 4, AllTargets = true, First = true }, -- First: também no 1º ataque (1º, 6º, 11º...)
			},
		},
		Shout = "Lirilì larilà!",
	},
	{
		Id = "TrippiTroppi",
		Name = "Trippi Troppi",
		Rarity = "Legendary",
		Role = "Speedy",
		Description = "Metade camarão, metade gato, cem por cento confuso: mia, nada e ninguém entende como.",
		Base = { Hp = 840, Atk = 115, Spd = 115 },
		Growth = { Hp = 10.6, Atk = 11.8, Spd = 5.6 },
		Passive = {
			Name = "Sete Vidas",
			Description = "Uma vez por luta, ao cair, volta com {1.Percent} da Vida e +{1.Fury} de Ataque.",
			Fx = "Phoenix",
			Effects = {
				{ Type = "Revive", Percent = 0.3, Uses = 1, Fury = 0.3 },
			},
		},
		Shout = "Trippi troppi, troppa trippa!",
	},
	{
		Id = "BonecaAmbalabu",
		Name = "Boneca Ambalabu",
		Rarity = "Mythic", -- 06/11/2026 (pedido do usuário): era Lendário
		Role = "Tank",
		Description = "Sapo de corpo de pneu e pernas humanas que encara todo mundo sem mudar a cara.",
		Base = { Hp = 1680, Atk = 90, Spd = 170 },
		Growth = { Hp = 16.9, Atk = 10.1, Spd = 2.5 },
		-- Modelo e habilidade do usuário (05/11/2026): vira pneu (animação "power_in") e atropela todos
		Passive = {
			Name = "Pneu Atropelador",
			Description = "No 1º ataque e depois a cada {1.Pattern#}, vira um pneu e atropela TODOS os inimigos: {1.Pattern.1.Multiplier} do seu ataque em cada um e −{1.Pattern.1.Debuff.Percent} de Velocidade por {1.Pattern.1.Debuff.Turns} turnos.",
			ArenaDescription = "No 1º ataque e depois a cada {1.Pattern#}, atropela todos os inimigos perto: {1.Pattern.1.Multiplier} do seu ataque e −{1.Pattern.1.Debuff.Percent} de Velocidade por {1.Pattern.1.Debuff.Turns:s}.",
			Fx = "TireRoll",
			Effects = {
				{
					Type = "AttackPattern",
					Repeat = true,
					Pattern = {
						{
							AllTargets = true,
							Multiplier = 1,
							Fx = "TireRoll",
							Debuff = { Stat = "Spd", Percent = 0.3, Turns = 2 },
						},
						{},
						{},
						{},
					},
				},
			},
		},
		Shout = "Ambalabu! Ambalabu!",
	},
	{
		Id = "ChimpanziniBananini",
		Name = "Chimpanzini Bananini",
		Rarity = "Legendary",
		Role = "Fighter",
		Description = "Chimpanzé que mora dentro de uma banana descascada e não divide a fruta com ninguém.",
		Base = { Hp = 1080, Atk = 125, Spd = 80 },
		Growth = { Hp = 13.4, Atk = 12.2, Spd = 4.3 },
		Passive = {
			Name = "Pulo na Cabeça",
			Description = "A cada {1.Pattern#}º ataque, pula {1.Pattern.3.Hits} vezes na cabeça do alvo, com {1.Pattern.3.Multiplier} do seu ataque cada.",
			Effects = {
				-- 13/11/2026 (pedido do usuário): no lugar da casca de banana (Trap 20%)
				{
					Type = "AttackPattern",
					Pattern = { {}, {}, { Hits = 3, SameTarget = true, Multiplier = 0.75, Fx = "HeadJump" } },
					Repeat = true,
				},
			},
		},
		Shout = "Chimpanzini bananini, wa-wa-wa!",
	},
	{
		Id = "BallerinaCappuccina",
		Name = "Ballerina Cappuccina",
		Rarity = "Mythic",
		Role = "Speedy",
		Description = "Bailarina de tutu rosa com uma xícara de cappuccino no lugar da cabeça, que nunca derrama uma gota.",
		Base = { Hp = 1080, Atk = 150, Spd = 140 },
		Growth = { Hp = 13.6, Atk = 14.4, Spd = 7.3 },
		Passive = {
			Name = "Pirueta",
			-- 13/11/2026 (pedido do usuário): era 25% de esquiva com revide de 0.5x e +30% no próximo golpe
			Description = "Depois de levar dano, o próximo ataque dela dá {1.Multiplier} do seu ataque (e ainda pode ser crítico).",
			Fx = "Pirouette",
			Effects = {
				{ Type = "HurtCharge", Multiplier = 2.75 }, -- 17/11/2026 (pedido do usuário): era 2x
			},
		},
		Shout = "Ballerina Cappuccina, mi-mi-mi!",
	},
	{
		Id = "CappuccinoAssassino",
		Name = "Cappuccino Assassino",
		Rarity = "Secret", -- 06/11/2026 (pedido do usuário): era Mítico
		Role = "Attacker",
		Description = "Xícara de cappuccino ninja com duas katanas que ataca antes de você terminar o café.",
		Base = { Hp = 1200, Atk = 380, Spd = 160 }, -- Vida 800 → 1200 (18/11/2026, pedido do usuário)
		Growth = { Hp = 14.6, Atk = 22, Spd = 5.5 },
		Passive = {
			Name = "Golpe Ninja",
			-- 06/11/2026 (pedido do usuário): saiu a execução
			-- 16/11/2026 (texto do usuário, exato): esquiva recarrega sem limite; só o revide é até 3 vezes
			Description = "+{1.Chance} de crítico\n\nComeça a partida com 100% de esquiva que dura até se esquivar.\n\nAté 3 vezes na partida, quando esquivar, revida com um golpe de {3.Multiplier} do seu ataque como dano verdadeiro\n\nEm Super chefes, o revide causa metade do dano.\n\nDano verdadeiro atravessa toda redução de dano e escudo.\n\nAo causar um crítico, recebe 100% de esquiva que dura até se esquivar.",
			-- Arena (17/11/2026): o atordoamento em segundos
			ArenaDescription = "+{1.Chance} de crítico\n\nComeça a partida com 100% de esquiva que dura até se esquivar.\n\nAté 3 vezes na partida, quando esquivar, revida com um golpe de {3.Multiplier} do seu ataque como dano verdadeiro e congela o inimigo enquanto revida\n\nDano verdadeiro atravessa toda redução de dano e escudo.\n\nAo causar um crítico, recebe 100% de esquiva que dura até se esquivar.",
			Fx = "Ninja",
			Effects = {
				{ Type = "Crit", Chance = 0.1 },
				-- 15/11/2026 (pedido do usuário): sempre 3 recargas, com qualquer estrela (o +1 por estrela saiu no mesmo dia)
				-- 16/11/2026 (pedido do usuário): sem limite de recargas (sem Recharges = todo crítico recarrega)
				{ Type = "FirstDodge" },
				-- 15/11/2026 (pedido do usuário): esquivou (de qualquer jeito) → revida com Multiplier × o próprio Ataque
				-- (BattleEngine riposte; pode critar). Antes: o dano do golpe esquivado + 1,5x o Ataque dele
				-- 16/11/2026: o revide sai no máximo Limit vezes na luta
				-- 17/11/2026 (pedido do usuário): StunTurns = o parry paralisa quem levou o revide
				-- 18/11/2026 (pedido do usuário): metade do dano do revide em Super chefe (SuperBossShare)
				-- Arena (18/11/2026, pedido do usuário): sem atordoar; ArenaFreeze = segundos do "parry" em que quem levou fica
				-- congelado (o relógio do próximo ataque dele para; BattleEngine riposte)
				{
					Type = "DodgeRiposte",
					Multiplier = 0.5, -- 18/11/2026 (pedido do usuário): era 1.25 (sem estrelas; cada estrela soma +50%)
					Limit = 3,
					-- 18/11/2026 (pedido do usuário): sem StunTurns, nunca atordoa (normal = só congela no visual; Arena = ArenaFreeze)
					SuperBossShare = 0.5,
					ArenaFreeze = 0.85,
				}, -- 15/11/2026: era 3
			},
		},
		Shout = "Cappuccino assassino!",
	},
	{
		Id = "FrigoCamelo",
		Name = "Frigo Camelo",
		Rarity = "Mythic",
		Role = "Tank",
		Description = "Camelo de botas com corpo de geladeira, sempre pronto para atravessar o deserto gelado.",
		Base = { Hp = 1920, Atk = 135, Spd = 75 },
		Growth = { Hp = 23.8, Atk = 13.6, Spd = 3.3 },
		Passive = {
			Name = "Câmara Fria",
			-- 06/11/2026 (pedido do usuário): escudo pela Vida máxima de cada um; a cura virou mais escudo
			-- 17/11/2026 (pedido do usuário): escudo pela Vida máxima DO FRIGO (sem OwnMaxHp); era 12% e 8% pela de cada um
			Description = "No começo da luta, dá a todo o time um escudo de {1.Percent} da Vida máxima do Frigo. A cada {2.Every} ataques, mais {2.Percent} da Vida máxima dele de escudo para o time.",
			Effects = {
				{ Type = "TeamShield", Percent = 0.08 },
				{ Type = "TeamShieldEvery", Percent = 0.1, Every = 3 },
			},
		},
		Shout = "Frigo camelo!",
	},
	{
		Id = "TralaleroTralala",
		Name = "Tralalero Tralala",
		Rarity = "Secret",
		Role = "Speedy",
		Description = "Tubarão azul de três pernas que corre pela praia de tênis azul e jura que é o dono da trend.",
		Base = { Hp = 1560, Atk = 210, Spd = 210 },
		Growth = { Hp = 19.3, Atk = 21.2, Spd = 10.3 },
		Passive = {
			Name = "Surfe Tralalá",
			Description = "{1.Chance} de chance de surfar em uma onda antes de atacar, acertando TODOS os inimigos com {1.Multiplier} do seu ataque.",
			ArenaDescription = "{1.Chance} de chance de surfar antes de bater, acertando todos os inimigos perto com {1.Multiplier} do seu ataque.",
			Effects = {
				{
					Type = "ExtraAttack",
					Chance = 0.3, -- 19/11/2026 (pedido do usuário): era 0.35
					Multiplier = 1.25, -- 19/11/2026 (pedido do usuário): era 1.5 (antes 0.7)
					Before = true,
					AllTargets = true,
					Fx = "Wave",
				},
			},
		},
		Shout = "Tralalero tralalà!",
	},
	{
		Id = "TungTungTungSahur",
		Name = "Tung Tung Tung Sahur",
		Rarity = "Secret",
		Role = "Attacker",
		Description = "Tronco de madeira de olhos arregalados que bate o taco na porta até você acordar para o sahur.",
		-- 13/11/2026 (pedido do usuário): era 1600/300. 20/11/2026 (pedido do usuário): +100 de Vida e +30 de Ataque (era 2100/250)
		Base = { Hp = 2200, Atk = 280, Spd = 150 },
		Growth = { Hp = 18.9, Atk = 29.3, Spd = 7.8 },
		Passive = {
			Name = "Tung! Tung! Tung!",
			Description = "A cada {1.Pattern#}º ataque, {1.Pattern.3.Hits} pancadas no alvo; a última dá {1.Pattern.3.FinalMultiplier} do seu ataque.",
			Effects = {
				{
					Type = "AttackPattern",
					-- 06/11/2026: última pancada 3x (era 2.5x); 20/11/2026 (pedido do usuário): 3.5x
					Pattern = { {}, {}, { Hits = 3, SameTarget = true, FinalMultiplier = 3.5, Fx = "Tung" } },
					Repeat = true,
				},
			},
		},
		Shout = "Tung tung tung... SAHUR!",
	},
	{
		Id = "BombardiroCrocodilo",
		Name = "Bombardiro Crocodilo",
		Rarity = "Secret",
		Role = "Tank",
		Description = "Crocodilo que virou avião bombardeiro e passa o dia sobrevoando a ilha de boca aberta.",
		Base = { Hp = 1600, Atk = 185, Spd = 170 }, -- 13/11/2026 (pedido do usuário): era Vida 2640 e Velocidade 105
		Growth = { Hp = 33, Atk = 18.9, Spd = 4.3 },
		Passive = {
			Name = "NUKE",
			Description = "No 1º ataque e depois a cada {1.Every}, em vez de bater, solta uma NUKE em TODOS os inimigos com {1.Multiplier} do seu ataque.",
			ArenaDescription = "No 1º ataque e depois a cada {1.Every}, em vez de bater, NUKE em todos os inimigos da Arena com {1.Multiplier} do seu ataque.",
			Effects = {
				-- 13/11/2026 (pedido do usuário): era 35% de chance por turno de bombardear todos com 0.45x
				-- Every: 1º, 5º, 9º ataque... (15/11/2026: a NUKE é o ataque do turno, no lugar do golpe)
				{ Type = "OpeningStrike", Multiplier = 3, Fx = "Bombs", Every = 4 },
			},
		},
		Shout = "Bombardiro crocodilo!",
	},
}

local byId: { [string]: Species } = {}
for _, species in LIST do
	byId[species.Id] = species
end

local SpeciesConfig = {
	List = LIST,
}

-- Espécie pelo id (nil se não existir)
function SpeciesConfig.get(id: string): Species?
	return byId[id]
end

return SpeciesConfig
]=]
SOURCES["src/shared/Events/ArenaBattleLayout.luau"] = [=[
--[[
	ArenaBattleLayout — os lugares do evento Arena no piso do Coliseu (iguais no servidor e no cliente; números em
	Config/ArenaBattleConfig). Tudo relativo ao centro do Coliseu, sem a altura do piso (Y = 0), menos a arquibancada.

		Layout.Sides                   → { "A", "B", "C", "D" } (a ordem do ArenaBattleConfig.Teams)
		Layout.team(side)              → a entrada do time no config (Name, Color, Angle)
		Layout.direction(side)         → do centro para a arquibancada dele
		Layout.right(side)             → a direita de quem está na arquibancada olhando para o centro
		Layout.formation(side, slot)   → onde o brainrot do slot fica antes da luta (1 = esquerda, 2 = meio, 3 = direita)
		Layout.Points                  → os 24 lugares de luta: 1–12 onde cada par se encontra, 13–24 as vagas do lado
		Layout.fightPoint(side, slot)  → índice em Points de onde o slot luta no começo
		Layout.opponent(side, slot)    → side, slot do alvo marcado no começo
		Layout.neighbor(side, offset)  → o time da direita (−1), da esquerda (+1) ou da frente (2)
		Layout.standCFrame(side)       → pivô do avatar em pé na arquibancada, olhando para o centro (com altura)
		Layout.cameraCFrame(side)      → câmera de quem luta (com altura)

	Pares do começo (cada time olhando para o centro): esquerda ↔ direita do time da esquerda (os dois se encontram na
	frente do portão entre as arquibancadas), meio ↔ meio do time da frente (no centro, os 4 do meio em losango).
	Vagas: uma do lado de cada um do par do portão (para o lado do centro) e 4 no centro (na direção dos portões), cada
	uma colada em 2 dos 4 do meio.
]]

local ArenaBattleConfig = require(script.Parent.Parent.Config.ArenaBattleConfig)

local config = ArenaBattleConfig

local Layout = {}

local sides: { string } = {}
local indexOf: { [string]: number } = {}
local teams: { [string]: { [string]: any } } = {}
for index, team in config.Teams do
	sides[index] = team.Side
	indexOf[team.Side] = index
	teams[team.Side] = team
end
Layout.Sides = sides

-- Direção de um ângulo de bússola (0 = norte = −Z, 90 = leste = +X)
local function compass(degrees: number): Vector3
	local angle = math.rad(degrees)
	return Vector3.new(math.sin(angle), 0, -math.cos(angle))
end

function Layout.team(side: string): { [string]: any }
	return teams[side]
end

function Layout.direction(side: string): Vector3
	return compass(teams[side].Angle)
end

-- Olhando para o centro (ângulo + 180), a direita fica 90° no sentido horário: ângulo − 90
function Layout.right(side: string): Vector3
	return compass(teams[side].Angle - 90)
end

-- O time da direita (offset −1: está no ângulo − 90), da esquerda (+1) ou da frente (2)
function Layout.neighbor(side: string, offset: number): string
	local count = #sides
	return sides[((indexOf[side] - 1 + offset) % count) + 1]
end

function Layout.formation(side: string, slot: number): Vector3
	return Layout.direction(side) * config.FormationRadius + Layout.right(side) * ((slot - 2) * config.FormationSpacing)
end

function Layout.opponent(side: string, slot: number): (string, number)
	if slot == 1 then
		return Layout.neighbor(side, 1), 3
	elseif slot == 3 then
		return Layout.neighbor(side, -1), 1
	end
	return Layout.neighbor(side, 2), 2
end

local function fightIndex(side: string, slot: number): number
	return (indexOf[side] - 1) * 3 + slot
end

function Layout.fightPoint(side: string, slot: number): number
	return fightIndex(side, slot)
end

-- Os 24 lugares
local points: { Vector3 } = {}
local cornerSpot = #sides * 3
for _, side in sides do
	-- Par do portão da direita: o 3 deste time com o 1 do time da direita
	local rightSide = Layout.neighbor(side, -1)
	local mine, theirs = Layout.formation(side, 3), Layout.formation(rightSide, 1)
	local middle = (mine + theirs) / 2
	local along = (theirs - mine).Unit
	local inward = -Vector3.new(middle.X, 0, middle.Z).Unit
	points[fightIndex(side, 3)] = middle - along * (config.CornerGap / 2)
	points[fightIndex(rightSide, 1)] = middle + along * (config.CornerGap / 2)
	points[cornerSpot + 1] = points[fightIndex(side, 3)] + inward * config.CornerSpotInward
	points[cornerSpot + 2] = points[fightIndex(rightSide, 1)] + inward * config.CornerSpotInward
	cornerSpot += 2
	-- Meio: perto do centro, do lado da arquibancada dele
	points[fightIndex(side, 2)] = Layout.direction(side) * config.CenterRadius
end
for _, degrees in { 0, 90, 180, 270 } do
	cornerSpot += 1
	points[cornerSpot] = compass(degrees) * config.CenterSpotRadius
end
-- Lista em ordem (as chaves foram preenchidas fora de ordem; assim a ordem de percorrer é sempre a mesma)
local ordered: { Vector3 } = {}
for index = 1, cornerSpot do
	ordered[index] = points[index]
end
Layout.Points = ordered

function Layout.standCFrame(side: string): CFrame
	local stand = config.Stand
	local position = Layout.direction(side) * stand.Radius + Vector3.new(0, stand.FeetY + 3, 0)
	return CFrame.lookAt(position, Vector3.new(0, position.Y, 0))
end

function Layout.cameraCFrame(side: string): CFrame
	local camera = config.Camera
	local direction = Layout.direction(side)
	local eye = direction * camera.Distance + Vector3.new(0, camera.Height, 0)
	local focus = direction * camera.LookRadius + Vector3.new(0, camera.LookHeight, 0)
	return CFrame.lookAt(eye, focus)
end

return Layout
]=]
SOURCES["src/shared/Types.luau"] = [=[
--[[
	Types — formato dos dados do jogo (só tipos, para documentar e ajudar o autocomplete).
]]

export type Talents = {
	Hp: number,
	Atk: number,
	Spd: number,
}

export type BrainrotData = {
	Id: string, -- identificador único deste brainrot (ex.: "b12")
	Species: string, -- id da espécie (ver Config/SpeciesConfig)
	Level: number,
	Aura: number, -- XP juntado; só vira nível quando o jogador aperta "subir" na mochila (paga moedas)
	Talents: Talents, -- talento ATUAL de cada stat, em % (soma isso à base do stat)
	TalentMax: Talents, -- até onde o talento de cada stat pode chegar treinando (20 a 100, sorteado ao chocar)
	Stars: number, -- 0 a 3 (fusão de estrelas)
	Passive: string, -- espécie de onde vem a passiva (começa a própria; muda na fusão)
	Locked: boolean, -- travado = não pode ser vendido nem usado em fusão
	Slot: number, -- lugar da vitrine do terreno (0 = guardado no inventário)
	HatchedAt: number, -- os.time() de quando chocou
	Diamonds: number, -- diamantes que ainda tem para gerar na vitrine (gasta até 0)
	DiamondMax: number, -- quantos veio (sorteado ao chocar; não muda; o máximo com as estrelas = Diamonds.max)
	Gold: number, -- moedas por segundo exposto na vitrine (sorteado ao chocar; nunca acaba; Shared/Brainrot/Gold)
	Artifact: string?, -- id do artefato equipado no 1º lugar (ArtifactConfig)
	Artifact2: string?, -- id do artefato do 2º lugar (14/11/2026)
	Mutation: string?, -- mutação (Config/MutationConfig: "Golden" = Dourado; sem = normal), 19/11/2026
	Size: number?, -- % a mais de tamanho, 0 a 400 (Config/SizeConfig; vem dos ovos do campo e de evento; sem = 0)
}

export type ArenaData = {
	Season: string,
	Trophies: number,
	MaxTrophies: number,
	Floor: number,
	Division: number,
	Wins: number,
	Losses: number,
	Streak: number,
	Fights: number,
	DayKey: number,
	DayWins: number,
	DayLosses: number,
	DayDefLoss: number,
	DayDefWin: number,
	DayFoes: { [string]: number },
	Recent: { number },
	Log: { { N: string, W: boolean, D: number, At: number } },
	Titles: { string },
	BoostUntil: number,
	Best: { Season: string, Max: number },
	ResetVersion: number,
	LadderEpoch: number?,
}

export type PlayerData = {
	DataVersion: number,
	Coins: number,
	Diamonds: number, -- moeda nova (05/11/2026): gerada pelos brainrots expostos na vitrine
	DevCombat: { Dodge: number, Thorns: number }, -- esquiva/espinhos extras do painel DEV (07/11/2026)
	Wins: number,
	TowerMaxFloor: number, -- maior andar da Torre vencido (0 = nenhum)
	TowerResumeFloor: number, -- sem uso desde 13/11/2026
	TowerStages: number, -- dificuldades da Torre completas (TowerConfig.Stages)
	Rebirths: number, -- rebirths feitos (Config/RebirthConfig; temporário, 15/11/2026)
	TowerBoss: { Period: number, Cleared: number }, -- Chefão da Torre: rodízio e maior dificuldade vencida
	VaultBonus: number, -- limite do Cofre a mais, para sempre (Chefão da Torre)
	Settings: { [string]: number }, -- Configurações do jogador (SettingsConfig.Options: id → valor de 0 a 1)
	ShopPurchases: { Rotation: number, Bought: { [string]: number } }, -- Máquina de Vendas: compras da rodada atual
	CratePurchases: { Rotation: number, Bought: { [string]: number } }, -- Loja de Caixas: compras da rodada atual
	Brainrots: { [string]: BrainrotData },
	NextBrainrotId: number, -- contador para os ids únicos
	InventoryCapacity: number,
	Index: { [string]: number }, -- espécies já descobertas → os.time() da primeira vez
	IndexClaimed: { [string]: boolean }, -- prêmios do Index já pegos (raridade → true; Shared/Config/IndexConfig)
	Eggs: { [string]: number }, -- ovos guardados na mochila: id do ovo → quantos
	EggSizes: { [string]: { number } }, -- tamanho de cada ovo guardado que tem tamanho (ovos do campo): id → lista
	Depot: { [string]: number }, -- Depósito do rebirth: ovos bloqueados (Config/DepotConfig)
	DepotSizes: { [string]: { number } },
	TradeUnlocked: boolean, -- pode doar e receber ovos
	Items: { [string]: number }, -- itens da Máquina de Vendas guardados (id → quantos)
	NextEggTalentBoosts: { [string]: number }, -- id do item (Tônico/Elixir) → fração; somam, um de cada (14/11/2026)
	NextEggTalentBoost: number, -- Tônico/Elixir do Talento: fração do teto somada ao talento do próximo ovo (13/11/2026)
	Vault: number, -- moedas esperando no Cofre do terreno
	Team: { string }, -- ids dos brainrots que seguem o jogador (até BrainrotConfig.TeamSize)
	UnlockedSlots: number, -- lugares liberados na vitrine do terreno
	GymBrainrots: { [string]: string }, -- academia do terreno: máquina (GymConfig) → id do brainrot que treina nela
	MineCarts: { [string]: string }, -- mina: carrinho ("1".."3", MineConfig) → id do brainrot dentro dele
	MineExpedition: { [string]: any }, -- expedição da mina (MineService): {} = nenhuma
	HouseLevel: number, -- nível da casa do terreno (HouseConfig; 1 a 10) = nível das 3 máquinas da academia
	PlotName: string, -- nome do terreno escolhido pelo dono ("" = "Terreno de <nick>"; HouseService)
	SlotLevels: { [string]: number }, -- nível de cada lugar da vitrine ("3" → 2); sem entrada = nível 1
	ShowcaseLevel: number, -- nível da antiga Vitrine de Aura (sem uso desde 05/11/2026)
	LastOnlineAt: number, -- os.time() da última vez online (saída, ou a marca de minuto do OfflineService)
	OfflineRate: number, -- Moedas/s (com o multiplicador) na saída: base do ganho de quando estava fora
	Restored: { [string]: boolean },
	GiftsOut: { [string]: { Egg: string, Size: number, To: number, At: number, Delivered: boolean? } }, -- doações de ovo no meio do caminho -- backups já devolvidos (DataConfig.Restores)
	OfflineDiamondRates: { [string]: number }, -- id do exposto → 💎/s na saída (diamantes de quando estava fora)
	OfflinePending: { Coins: number?, Diamonds: number?, Seconds: number?, Capped: boolean? }, -- esperando o "Coletar" do popup
	Upgrades: { [string]: number }, -- melhoria (ver UpgradeConfig) → nível (1 = de graça)
	Skills: { [string]: number }, -- skills compradas (SkillConfig): id → nível (desde 06/11/2026)
	RedeemedCodes: { [string]: number }, -- código → os.time() do resgate
	EventStats: { Events: number, CosmicEggs: number, Steals: number, Kos: number },
	Arena: ArenaData,
	ArenaRanked: ArenaData, -- Arena Ranqueada de 4 times (16/11/2026)
	Tutorial: { [string]: any }, -- tutorial (Shared/Brainrot/Tutorial): marcas dos passos, ReachedStep (nome do passo mais longe; Reached = número antigo), Skipped (DEV)
	Statistics: {
		JoinCount: number,
		FirstJoinAt: number,
		LastJoinAt: number,
		PlayTime: number,
		EggsOpened: number,
		Fusions: number,
		JunkSold: number,
		TowerWins: number,
	},
}

return {}
]=]
SOURCES["tools/json"] = [=[
--[[
	json — JSON em Luau puro (o site não tem o serde do Lune). encode(valor) → texto; decode(texto) → valor.
	Tabela com 1..n sem buracos vira lista; o resto vira objeto (chaves em texto).
]]

local Json = {}

local ESCAPES =
	{ ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function encodeString(text: string): string
	return '"'
		.. text:gsub('[%c"\\]', function(char)
			return ESCAPES[char] or string.format("\\u%04x", string.byte(char))
		end)
		.. '"'
end

local function isList(value: { [any]: any }): boolean
	local count = 0
	for key in value do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
			return false
		end
		count += 1
	end
	return count == #value
end

local function encode(value: any, out: { string })
	local kind = type(value)
	if value == nil then
		table.insert(out, "null")
	elseif kind == "boolean" then
		table.insert(out, if value then "true" else "false")
	elseif kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			table.insert(out, "null")
		elseif value % 1 == 0 and math.abs(value) < 2 ^ 53 then
			table.insert(out, string.format("%d", value))
		else
			table.insert(out, string.format("%.14g", value))
		end
	elseif kind == "string" then
		table.insert(out, encodeString(value))
	elseif kind == "table" then
		if next(value) ~= nil and isList(value) then
			table.insert(out, "[")
			for index, item in ipairs(value) do
				if index > 1 then
					table.insert(out, ",")
				end
				encode(item, out)
			end
			table.insert(out, "]")
		else
			table.insert(out, "{")
			local first = true
			local keys = {}
			for key in value do
				if type(key) == "string" or type(key) == "number" then
					table.insert(keys, key)
				end
			end
			table.sort(keys, function(a, b)
				return tostring(a) < tostring(b)
			end)
			for _, key in keys do
				local item = value[key]
				if type(item) ~= "function" then
					if not first then
						table.insert(out, ",")
					end
					first = false
					table.insert(out, encodeString(tostring(key)))
					table.insert(out, ":")
					encode(item, out)
				end
			end
			table.insert(out, "}")
		end
	else
		table.insert(out, "null")
	end
end

function Json.encode(value: any): string
	local out = {}
	encode(value, out)
	return table.concat(out)
end

function Json.decode(text: string): any
	local index = 1
	local function skip()
		index = string.find(text, "[^ \t\r\n]", index) or #text + 1
	end
	local parseValue
	local function parseString(): string
		index += 1 -- abre aspas
		local parts = {}
		while true do
			local char = string.sub(text, index, index)
			if char == "" then
				error("JSON: texto sem fim")
			elseif char == '"' then
				index += 1
				break
			elseif char == "\\" then
				local nextChar = string.sub(text, index + 1, index + 1)
				local map =
					{ b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
				if nextChar == "u" then
					local code = tonumber(string.sub(text, index + 2, index + 5), 16) or 63
					table.insert(parts, utf8.char(code))
					index += 6
				else
					table.insert(parts, map[nextChar] or nextChar)
					index += 2
				end
			else
				local stop = string.find(text, '["\\]', index) or #text + 1
				table.insert(parts, string.sub(text, index, stop - 1))
				index = stop
			end
		end
		return table.concat(parts)
	end
	function parseValue(): any
		skip()
		local char = string.sub(text, index, index)
		if char == "{" then
			index += 1
			local result = {}
			skip()
			if string.sub(text, index, index) == "}" then
				index += 1
				return result
			end
			while true do
				skip()
				local key = parseString()
				skip()
				index += 1 -- dois-pontos
				result[key] = parseValue()
				skip()
				local sep = string.sub(text, index, index)
				index += 1
				if sep == "}" then
					return result
				end
			end
		elseif char == "[" then
			index += 1
			local result = {}
			skip()
			if string.sub(text, index, index) == "]" then
				index += 1
				return result
			end
			while true do
				table.insert(result, parseValue())
				skip()
				local sep = string.sub(text, index, index)
				index += 1
				if sep == "]" then
					return result
				end
			end
		elseif char == '"' then
			return parseString()
		elseif string.sub(text, index, index + 3) == "true" then
			index += 4
			return true
		elseif string.sub(text, index, index + 4) == "false" then
			index += 5
			return false
		elseif string.sub(text, index, index + 3) == "null" then
			index += 4
			return nil
		end
		local number = string.match(text, "^-?%d+%.?%d*[eE]?[-+]?%d*", index)
		if not number or number == "" then
			error(`JSON inválido perto de {index}`)
		end
		index += #number
		return tonumber(number)
	end
	return parseValue()
end

return Json
]=]
SOURCES["tools/polyfill"] = [=[
--[[
	polyfill — o pouco do Roblox que o motor de luta e as configs usam, em Luau puro (para o site; no Lune vale o
	@lune/roblox). Vector3 (contas, Magnitude, Unit), CFrame.lookAt (só guarda a posição e a direção), Color3 (fromRGB,
	fromHSV, R/G/B, ToHex), Enum (qualquer Enum.X.Y vira um texto). Faltou algo: o erro diz o nome; pôr aqui.
]]

local Vector3 = {}
local V = {}

local function vec(x: number, y: number, z: number)
	return setmetatable({ X = x, Y = y, Z = z }, V)
end

V.__index = function(self, key)
	if key == "Magnitude" then
		return math.sqrt(self.X * self.X + self.Y * self.Y + self.Z * self.Z)
	elseif key == "Unit" then
		local m = math.sqrt(self.X * self.X + self.Y * self.Y + self.Z * self.Z)
		if m == 0 then
			return vec(0, 0, 0)
		end
		return vec(self.X / m, self.Y / m, self.Z / m)
	end
	return rawget(V, key)
end
function V.__add(a, b)
	return vec(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
function V.__sub(a, b)
	return vec(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
function V.__mul(a, b)
	if type(a) == "number" then
		return vec(a * b.X, a * b.Y, a * b.Z)
	elseif type(b) == "number" then
		return vec(a.X * b, a.Y * b, a.Z * b)
	end
	return vec(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
function V.__div(a, b)
	if type(b) == "number" then
		return vec(a.X / b, a.Y / b, a.Z / b)
	end
	return vec(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
end
function V.__unm(a)
	return vec(-a.X, -a.Y, -a.Z)
end
function V.__eq(a, b)
	return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end
function V.__tostring(a)
	return `{a.X}, {a.Y}, {a.Z}`
end
function V.Dot(a, b)
	return a.X * b.X + a.Y * b.Y + a.Z * b.Z
end
function V.Cross(a, b)
	return vec(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X)
end
function V.Lerp(a, b, t)
	return a + (b - a) * t
end
function V.FuzzyEq(a, b, epsilon)
	return (a - b).Magnitude <= (epsilon or 1e-5)
end

function Vector3.new(x: number?, y: number?, z: number?)
	return vec(x or 0, y or 0, z or 0)
end
Vector3.zero = vec(0, 0, 0)
Vector3.one = vec(1, 1, 1)
Vector3.xAxis = vec(1, 0, 0)
Vector3.yAxis = vec(0, 1, 0)
Vector3.zAxis = vec(0, 0, 1)

-- CFrame: só o que a Arena usa (a posição de quem assiste); sem rotação de verdade
local CFrame = {}
local C = {}
C.__index = C
function CFrame.new(x: any, y: number?, z: number?)
	local position = if type(x) == "table" then x else vec(x or 0, y or 0, z or 0)
	return setmetatable({ Position = position, LookVector = vec(0, 0, -1) }, C)
end
function CFrame.lookAt(at: any, target: any)
	return setmetatable({ Position = at, LookVector = (target - at).Unit }, C)
end
function C.__add(a, b)
	return setmetatable({ Position = a.Position + b, LookVector = a.LookVector }, C)
end
function C.__mul(a, b)
	if getmetatable(b) == V then
		return a.Position + b
	end
	return setmetatable({ Position = a.Position + b.Position, LookVector = a.LookVector }, C)
end
CFrame.identity = CFrame.new()

local Color3 = {}
local K = {}
K.__index = K
local function color(r: number, g: number, b: number)
	return setmetatable({ R = r, G = g, B = b }, K)
end
function Color3.new(r: number?, g: number?, b: number?)
	return color(r or 0, g or 0, b or 0)
end
function Color3.fromRGB(r: number?, g: number?, b: number?)
	return color((r or 0) / 255, (g or 0) / 255, (b or 0) / 255)
end
function Color3.fromHSV(h: number, s: number, v: number)
	local i = math.floor(h * 6)
	local f = h * 6 - i
	local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
	local k = i % 6
	if k == 0 then
		return color(v, t, p)
	elseif k == 1 then
		return color(q, v, p)
	elseif k == 2 then
		return color(p, v, t)
	elseif k == 3 then
		return color(p, q, v)
	elseif k == 4 then
		return color(t, p, v)
	end
	return color(v, p, q)
end
function Color3.fromHex(hex: string)
	hex = hex:gsub("#", "")
	return Color3.fromRGB(tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16))
end
function K.ToHex(self)
	return string.format(
		"%02X%02X%02X",
		math.floor(self.R * 255 + 0.5),
		math.floor(self.G * 255 + 0.5),
		math.floor(self.B * 255 + 0.5)
	)
end
function K.Lerp(a, b, t)
	return color(a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t)
end

-- Enum.Material.Metal → "Enum.Material.Metal" (as configs só guardam)
local Enum = setmetatable({}, {
	__index = function(_, group)
		return setmetatable({}, {
			__index = function(_, item)
				return `Enum.{group}.{item}`
			end,
		})
	end,
})

-- Tipos de dados que só aparecem em configs de visual: qualquer construtor devolve uma tabela
local function opaque(name: string)
	return setmetatable({}, {
		__index = function(_, key)
			return function(...)
				return { __type = name, __ctor = key, ... }
			end
		end,
	})
end

local typeNames = { [V] = "Vector3", [C] = "CFrame", [K] = "Color3" }

return {
	Vector3 = Vector3,
	CFrame = CFrame,
	Color3 = Color3,
	Enum = Enum,
	UDim2 = opaque("UDim2"),
	UDim = opaque("UDim"),
	Vector2 = opaque("Vector2"),
	ColorSequence = opaque("ColorSequence"),
	ColorSequenceKeypoint = opaque("ColorSequenceKeypoint"),
	NumberSequence = opaque("NumberSequence"),
	NumberSequenceKeypoint = opaque("NumberSequenceKeypoint"),
	NumberRange = opaque("NumberRange"),
	BrickColor = opaque("BrickColor"),
	Font = opaque("Font"),
	typeof = function(value: any): string
		local meta = type(value) == "table" and getmetatable(value)
		return (meta and typeNames[meta]) or typeof(value)
	end,
}
]=]
SOURCES["tools/runtime"] = [=[
--[[
	runtime — roda módulos do jogo (src/) fora do Roblox. Luau puro: serve no Lune (loader.luau) e no site (engine.luau).

	Runtime.new(host) → { require = function("shared/Config/SpeciesConfig"), clock = relógio de mentira (makeClock) }
	host = {
		files = { ["src/shared/Config/X.luau"] = true, ... },    -- arquivos que existem
		dirs = { ["src/shared/Config"] = { "X.luau", ... }, ... }, -- pastas e o que tem dentro
		read = function(path) → texto,
		load = function(texto, nome, ambiente) → função,
		globals = { Vector3 = ..., Color3 = ..., ... },         -- o que falta do Roblox (Lune: @lune/roblox; site: polyfill)
		onLoad = function(path)?,                                  -- avisa cada arquivo carregado (build do site)
	}
	Monta um "game" de mentira: ReplicatedStorage.Shared = src/shared, ServerScriptService.Server = src/server. Cada
	módulo ganha o próprio `script` (script.Parent funciona) e um `require` que lê o arquivo.
]]

local ROOT = "src"

local Runtime = {}

---------------------------------------------------------------- Random (o do Roblox não existe fora dele)

-- xorshift32: não é o gerador do Roblox, a mesma semente dá outra luta (a média é a mesma)
local RandomClass = {}
RandomClass.__index = RandomClass

local function makeRandom(seed: number?)
	local s = math.floor(seed or (os.clock() * 1e6 + math.random(1, 1e6))) % 4294967296
	if s == 0 then
		s = 2463534242
	end
	return setmetatable({ _s = s }, RandomClass)
end

function RandomClass:_next(): number
	local x = self._s
	x = bit32.bxor(x, bit32.lshift(x, 13))
	x = bit32.bxor(x, bit32.rshift(x, 17))
	x = bit32.bxor(x, bit32.lshift(x, 5))
	self._s = x
	return x / 4294967296
end

function RandomClass:NextNumber(min: number?, max: number?): number
	local low, high = min or 0, max or 1
	return low + (high - low) * self:_next()
end

function RandomClass:NextInteger(min: number, max: number): number
	return math.floor(min + (max - min + 1) * self:_next())
end

function RandomClass:Shuffle(list: { any })
	for i = #list, 2, -1 do
		local j = self:NextInteger(1, i)
		list[i], list[j] = list[j], list[i]
	end
end

function RandomClass:Clone()
	return setmetatable({ _s = self._s }, RandomClass)
end

Runtime.Random = { new = makeRandom }

-- task: o motor de luta não espera nada; só o básico para nenhum módulo quebrar
Runtime.task = {
	spawn = function(fn, ...)
		return coroutine.wrap(fn)(...)
	end,
	defer = function(fn, ...)
		return coroutine.wrap(fn)(...)
	end,
	delay = function() end,
	wait = function()
		return 0
	end,
	cancel = function() end,
}

-- Relógio de mentira (luta da Piñata, em tempo real): com clock.now posto, os.clock() dos módulos dá essa hora e o
-- task.delay vai para clock.pending (o simcore roda na hora certa). Sem ele, os.clock é o de verdade e o delay não faz nada
local function makeClock()
	local clock = { now = nil :: number?, pending = nil :: { any }?, Random = Runtime.Random }
	local fakeOs = setmetatable({
		clock = function()
			return clock.now or os.clock()
		end,
	}, { __index = os })
	local fakeTask = table.clone(Runtime.task)
	fakeTask.delay = function(seconds: number?, fn: (...any) -> (), ...)
		if clock.pending and clock.now then
			table.insert(clock.pending, { At = clock.now + (seconds or 0), Fn = fn, Args = table.pack(...) })
		end
	end
	return clock, fakeOs, fakeTask
end

function Runtime.new(host: any)
	local files, dirs = host.files, host.dirs
	local clock, fakeOs, fakeTask = makeClock()
	local nodes: { [string]: any } = {}
	local cache: { [string]: any } = {}

	local function isFile(path: string): boolean
		return files[path] == true
	end
	local function isDir(path: string): boolean
		return dirs[path] ~= nil
	end

	local Node = {}
	local function node(path: string, name: string, parent: any?)
		local found = nodes[path]
		if found then
			return found
		end
		local self = setmetatable({ __path = path, __name = name, __parent = parent }, Node)
		nodes[path] = self
		return self
	end

	local function child(self: any, key: string): any?
		local sub = `{rawget(self, "__path")}/{key}`
		if isFile(sub .. ".luau") or isFile(sub .. ".lua") or isDir(sub) then
			return node(sub, key, self)
		end
		return nil
	end

	local methods = {}
	function methods.FindFirstChild(self: any, key: string)
		return child(self, key)
	end
	function methods.WaitForChild(self: any, key: string)
		local found = child(self, key)
		assert(found, `WaitForChild: {key} não existe em {rawget(self, "__path")}`)
		return found
	end
	function methods.GetChildren(self: any)
		local path = rawget(self, "__path")
		local list = {}
		for _, entry in dirs[path] or {} do
			local name = entry:gsub("%.luau$", ""):gsub("%.lua$", "")
			if name ~= "init" then
				table.insert(list, node(`{path}/{name}`, name, self))
			end
		end
		table.sort(list, function(a, b)
			return rawget(a, "__name") < rawget(b, "__name")
		end)
		return list
	end
	function methods.IsA(self: any, class: string)
		local path = rawget(self, "__path")
		if class == "ModuleScript" or class == "LuaSourceContainer" then
			return isFile(path .. ".luau") or isFile(path .. ".lua")
		end
		return class == "Folder" or class == "Instance"
	end
	function methods.GetFullName(self: any)
		return rawget(self, "__path")
	end
	function methods.GetAttribute()
		return nil
	end

	Node.__index = function(self, key)
		if key == "Parent" then
			return rawget(self, "__parent")
		elseif key == "Name" then
			return rawget(self, "__name")
		elseif key == "ClassName" then
			return if methods.IsA(self, "ModuleScript") then "ModuleScript" else "Folder"
		elseif methods[key] then
			return methods[key]
		end
		return child(self, key)
	end
	Node.__tostring = function(self)
		return rawget(self, "__name")
	end

	local function serviceWith(name: string, path: string)
		return setmetatable({}, {
			__index = function(_, key)
				if key == name then
					return node(path, name, nil)
				end
				return nil
			end,
		})
	end
	local services = {
		ReplicatedStorage = serviceWith("Shared", `{ROOT}/shared`),
		ServerScriptService = serviceWith("Server", `{ROOT}/server`),
	}
	local empty = setmetatable({}, {
		__index = function()
			return function() end
		end,
	})
	local game = {
		GetService = function(_, name: string)
			return services[name] or empty
		end,
	}

	local base: { [string]: any } = {}
	for key, value in host.globals or {} do
		base[key] = value
	end
	base.Random = base.Random or Runtime.Random
	base.task = fakeTask
	base.os = fakeOs
	base.game = game
	base.workspace = empty
	base.warn = function(...)
		print("[aviso]", ...)
	end

	local requireModule
	local function sourcePath(target: any): string
		local path = rawget(target, "__path")
		for _, candidate in { path .. ".luau", path .. ".lua", path .. "/init.luau", path .. "/init.lua" } do
			if isFile(candidate) then
				return candidate
			end
		end
		error(`módulo não achado: {path}`)
	end

	function requireModule(target: any): any
		local file = sourcePath(target)
		if cache[file] ~= nil then
			return cache[file]
		end
		if host.onLoad then
			host.onLoad(file)
		end
		-- Ambiente numa tabela só (o Lune não olha o __index do ambiente)
		local env = table.clone(base)
		env.script = target
		env.require = requireModule
		local result = host.load(host.read(file), file, env)()
		cache[file] = result
		return result
	end

	return {
		clock = clock,
		require = function(path: string): any
			local parts = string.split(path, "/")
			local current = node(`{ROOT}/{parts[1]}`, parts[1], nil)
			for i = 2, #parts do
				current = child(current, parts[i])
				assert(current, `não existe: {path}`)
			end
			return requireModule(current)
		end,
	}
end

return Runtime
]=]
SOURCES["tools/simcore"] = [=[
--[[
	simcore — o simulador em si (Luau puro: serve no Lune e no site).

	local Sim = require(simcore)(requireGame)   -- requireGame("shared/Config/X") = o módulo do jogo (runtime.luau)
	Sim.data() → espécies (Épico para cima), artefatos de luta, raridades, mutações, limites
	Sim.run({ Runs, Teams = { A = { ["1"] = brainrot, ... }, B = {...} } }) → vitórias, tempo e dano por brainrot
	Sim.run({ Mode = "Pinata", Runs, Teams = { A = {...} } }) → dano do time A na Piñata Absurda (BrawlSkills de verdade)
	brainrot = { Species, Level, Stars, Mutation?, Artifact?, Artifact2?, Talent? (% nos três stats) }
	Monta o brainrot como o BattleService:SpecFromBrainrot + bônus de base (sem a árvore de skills do dono) e roda o
	motor de verdade do PvP (src/server/Combat/ArenaEngine).
]]

return function(requireGame: (string) -> any, clock: any?)
	local SpeciesConfig = requireGame("shared/Config/SpeciesConfig")
	local RarityConfig = requireGame("shared/Config/RarityConfig")
	local ArtifactConfig = requireGame("shared/Config/ArtifactConfig")
	local BrainrotConfig = requireGame("shared/Config/BrainrotConfig")
	local CombatConfig = requireGame("shared/Config/CombatConfig")
	local MutationConfig = requireGame("shared/Config/MutationConfig")
	local BrainrotStats = requireGame("shared/Brainrot/BrainrotStats")
	local BattleDamage = requireGame("shared/Brainrot/BattleDamage")
	local PassiveText = requireGame("shared/Brainrot/PassiveText")
	local ArenaEngine = requireGame("server/Combat/ArenaEngine")

	local MIN_RARITY = "Epic"

	local function hex(color: any): string
		return string.format(
			"#%02x%02x%02x",
			math.floor(color.R * 255 + 0.5),
			math.floor(color.G * 255 + 0.5),
			math.floor(color.B * 255 + 0.5)
		)
	end

	local function rarityIndex(id: string): number
		for index, rarity in RarityConfig.List do
			if rarity.Id == id then
				return index
			end
		end
		return 0
	end

	local function speciesList(): { any }
		local list = {}
		for _, species in SpeciesConfig.List do
			if rarityIndex(species.Rarity) >= rarityIndex(MIN_RARITY) then
				local ok, text = pcall(PassiveText.describe, species.Passive, 0)
				table.insert(list, {
					Id = species.Id,
					Name = species.Name,
					Rarity = species.Rarity,
					Role = species.Role,
					Base = species.Base,
					Passive = if ok then text else nil,
				})
			end
		end
		table.sort(list, function(a, b)
			local ra, rb = rarityIndex(a.Rarity), rarityIndex(b.Rarity)
			if ra ~= rb then
				return ra > rb
			end
			return a.Name < b.Name
		end)
		return list
	end

	local function dumpData()
		local rarities = {}
		for _, rarity in RarityConfig.List do
			table.insert(rarities, {
				Id = rarity.Id,
				Name = rarity.Name,
				Color = hex(rarity.Color),
				Rainbow = rarity.Rainbow == true,
			})
		end
		local artifacts = {}
		for _, artifact in ArtifactConfig.List do
			local combat = artifact.Stats ~= nil or (artifact.Effects ~= nil and #artifact.Effects > 0)
			if combat then
				table.insert(artifacts, {
					Id = artifact.Id,
					Name = artifact.Name,
					Rarity = artifact.Rarity,
					Value = artifact.ValueText,
					Description = artifact.Description,
				})
			end
		end
		local mutations = {}
		for _, id in MutationConfig.ByRarity do
			local mutation = MutationConfig.get(id)
			if mutation then
				table.insert(mutations, { Id = id, Name = mutation.Name, Bonus = mutation.StatBonus })
			end
		end
		return {
			Species = speciesList(),
			Mutations = mutations,
			Artifacts = artifacts,
			Rarities = rarities,
			MaxLevel = BrainrotConfig.MaxLevel,
			MaxStars = BrainrotConfig.MaxStars,
			MaxTalent = BrainrotConfig.MaxTalent,
			Pinata = (function()
				local config = requireGame("shared/Config/EventConfig").Events.Pinata
				return { Duration = config.Duration, Reduction = config.DamageReduction or 0, Goal = config.GoalDamage }
			end)(),
		}
	end

	---------------------------------------------------------------- lutas

	local function brainrotOf(entry: any): any
		local talent = math.clamp(tonumber(entry.Talent) or 0, 0, BrainrotConfig.MaxTalent)
		return {
			Id = "sim",
			Species = entry.Species,
			Passive = entry.Species,
			Level = math.clamp(math.floor(tonumber(entry.Level) or 1), 1, BrainrotConfig.MaxLevel),
			Stars = math.clamp(math.floor(tonumber(entry.Stars) or 0), 0, BrainrotConfig.MaxStars),
			Mutation = if entry.Mutation and entry.Mutation ~= "" then entry.Mutation else nil,
			Talents = { Hp = talent, Atk = talent, Spd = talent },
			TalentMax = { Hp = 100, Atk = 100, Spd = 100 },
			Artifact = if entry.Artifact and entry.Artifact ~= "" then entry.Artifact else nil,
			Artifact2 = if entry.Artifact2 and entry.Artifact2 ~= "" then entry.Artifact2 else nil,
			Size = 0,
		}
	end

	-- Igual ao BattleService:SpecFromBrainrot + ApplyBonuses (só os bônus de base do CombatConfig, sem árvore de skills)
	local function specOf(entry: any): any
		local brainrot = brainrotOf(entry)
		local stats = BrainrotStats.get(brainrot)
		local extras = {}
		if CombatConfig.BaseDodgeChance > 0 then
			table.insert(extras, { Type = "Dodge", Chance = CombatConfig.BaseDodgeChance, Silent = true })
		end
		if CombatConfig.BaseThornsPercent > 0 then
			table.insert(extras, { Type = "Reflect", Percent = CombatConfig.BaseThornsPercent, Silent = true })
		end
		return {
			Species = brainrot.Species,
			Passive = brainrot.Passive,
			Level = brainrot.Level,
			Stars = brainrot.Stars,
			Mutation = brainrot.Mutation,
			Stats = {
				Hp = math.floor(stats.Hp + 0.5),
				Atk = math.floor(stats.Atk + 0.5),
				Spd = math.floor(stats.Spd + 0.5),
			},
			SpdTalent = brainrot.Talents.Spd,
			ArtifactEffects = ArtifactConfig.effectsOf(brainrot),
			Artifacts = ArtifactConfig.equipped(brainrot),
			Scale = 1,
			Size = 0,
		}
	end

	local function runFights(input: any)
		local runs = math.clamp(math.floor(tonumber(input.Runs) or 100), 1, 2000)
		local teams, specs = {}, {}
		for _, side in { "A", "B" } do
			local slots = {}
			specs[side] = {}
			for key, entry in input.Teams[side] or {} do
				local slot = tonumber(key) -- o JSON traz "1", "2", "3"
				if slot and entry and entry.Species and SpeciesConfig.get(entry.Species) then
					slots[slot] = specOf(entry)
					specs[side][slot] = slots[slot]
				end
			end
			table.insert(teams, { Side = side, Slots = slots })
		end
		if next(specs.A) == nil or next(specs.B) == nil then
			return { Error = "Ponha pelo menos um brainrot em cada time." }
		end

		local wins = { A = 0, B = 0 }
		local durationSum = 0
		local perUnit: { [string]: any } = {}
		local reasons = {}
		local sample = nil
		local failures = 0
		for index = 1, runs do
			local ok, script = pcall(ArenaEngine.run, teams, { Seed = index * 7919 + 13 })
			if not ok then
				failures += 1
				if failures == 1 then
					sample = { Error = tostring(script) }
				end
				continue
			end
			local winner = script.Result.Winner
			if winner then
				wins[winner] = (wins[winner] or 0) + 1
			end
			reasons[script.Result.Reason or "?"] = (reasons[script.Result.Reason or "?"] or 0) + 1
			durationSum += script.Result.WorldTime or 0
			local tally = BattleDamage.tally(script)
			for key, unitInfo in script.Units do
				local row = perUnit[key]
				if not row then
					row = {
						Key = key,
						Side = unitInfo.Side,
						Slot = unitInfo.Slot,
						Species = unitInfo.Species,
						MaxHp = unitInfo.MaxHp,
						Atk = unitInfo.Atk,
						Spd = unitInfo.Spd,
						Dealt = 0,
						Taken = 0,
						Healed = 0,
						Survived = 0,
					}
					perUnit[key] = row
				end
				row.Dealt += tally.Dealt[key] or 0
				row.Taken += tally.Taken[key] or 0
				row.Healed += tally.Healed[key] or 0
				if (script.Result.FinalHp[key] or 0) > 0 then
					row.Survived += 1
				end
			end
			if index == 1 then
				sample = { Duration = script.Result.WorldTime, Winner = winner, Events = #script.Events }
			end
		end
		local done = runs - failures
		local units = {}
		for _, row in perUnit do
			row.Dealt = math.floor(row.Dealt / math.max(1, done) + 0.5)
			row.Taken = math.floor(row.Taken / math.max(1, done) + 0.5)
			row.Healed = math.floor(row.Healed / math.max(1, done) + 0.5)
			row.Survived = row.Survived / math.max(1, done)
			table.insert(units, row)
		end
		table.sort(units, function(a, b)
			if a.Side ~= b.Side then
				return a.Side < b.Side
			end
			return a.Slot < b.Slot
		end)
		return {
			Runs = done,
			Failures = failures,
			Wins = wins,
			Draws = done - (wins.A or 0) - (wins.B or 0),
			AvgSeconds = math.floor(durationSum / math.max(1, done) * 10 + 0.5) / 10,
			Reasons = reasons,
			Units = units,
			Sample = sample,
		}
	end

	---------------------------------------------------------------- Piñata Absurda

	-- A briga do Coliseu em tempo real (src/server/Events/BrawlSkills, o mesmo do jogo) contra o burro parado:
	-- o laço do BrawlService (updateUnit) e o golpe do Pinata.onHit (redução, Chamas de Goes, Jakalopita) refeitos aqui,
	-- com relógio de mentira (runtime clock). Os brainrots já começam colados no burro (no jogo eles andam até ele).
	local function runPinata(input: any)
		assert(clock, "relógio de mentira faltando (runtime.clock)")
		local BrawlSkills = requireGame("server/Events/BrawlSkills")
		local BrawlConfig = requireGame("shared/Config/BrawlConfig")
		local EventConfig = requireGame("shared/Config/EventConfig")
		local config = EventConfig.Events.Pinata
		local runs = math.clamp(math.floor(tonumber(input.Runs) or 100), 1, 500)
		local duration = tonumber(input.Duration) or config.Duration
		local reduction = if input.Reduction ~= nil
			then tonumber(input.Reduction) or 0
			else (config.DamageReduction or 0)

		local entries = {}
		for key, entry in (input.Teams and input.Teams.A) or {} do
			local slot = tonumber(key)
			if slot and entry and entry.Species and SpeciesConfig.get(entry.Species) then
				table.insert(entries, { Slot = slot, Entry = entry })
			end
		end
		table.sort(entries, function(a, b)
			return a.Slot < b.Slot
		end)
		if #entries == 0 then
			return { Error = "Ponha pelo menos um brainrot no Time A." }
		end

		local perUnit = {}
		for _, item in entries do
			local brainrot = brainrotOf(item.Entry)
			local stats = BrainrotStats.get(brainrot)
			perUnit[item.Slot] = {
				Side = "A",
				Slot = item.Slot,
				Species = brainrot.Species,
				Atk = stats.Atk,
				Spd = stats.Spd,
				Hp = stats.Hp,
				Total = 0,
				Basic = 0,
				Skill = 0,
				Goes = 0,
				Jakalopita = 0,
				Hits = 0,
			}
		end

		local totalSum, best, worst = 0, 0, math.huge
		local failures, firstError = 0, nil
		for index = 1, runs do
			local ok, err = pcall(function()
				local rng = clock.Random.new(index * 7919 + 13)
				local owner = { UserId = 1, Name = "Sim" }
				local units = {}
				local runDamage = 0
				local function add(row: any, source: string, amount: number)
					row[source] += amount
					row.Total += amount
					runDamage += amount
				end
				local function onHit(unit: any, multiplier: number, basic: boolean?)
					local row = perUnit[unit.Index]
					local variation = rng:NextNumber(CombatConfig.DamageMin, CombatConfig.DamageMax)
					local amount = row.Atk * variation * multiplier
					local pierce = 0
					for _, effect in unit.Effects.Pierce or {} do
						pierce += effect.ReductionPierce or 0
					end
					local pierced = amount * reduction * math.min(1, pierce)
					amount *= 1 - reduction * (1 - math.min(1, pierce))
					row.Hits += 1
					add(row, if basic then "Basic" else "Skill", amount - pierced)
					if pierced > 0 then
						add(row, "Goes", pierced)
					end
					local share = 0
					for _, effect in unit.Effects.MaxHpHit or {} do
						share += effect.Percent or 0
					end
					if share > 0 then
						add(row, "Jakalopita", amount * share * ArtifactConfig.MaxHpHitPinataMultiplier)
					end
				end
				local ground = { X = 0, Y = 0, Z = 0 }
				local ctx = {
					rng = rng,
					enemiesNear = function()
						return {}
					end,
					allies = function()
						return units
					end,
					emit = function() end,
					bagGround = function()
						return ground
					end,
					hitBag = function(unit: any, multiplier: number)
						onHit(unit, multiplier)
					end,
					changed = function() end,
					onKo = function() end,
					onRevive = function() end,
				}
				for _, item in entries do
					local brainrot = brainrotOf(item.Entry)
					local species = SpeciesConfig.get(brainrot.Species)
					local role = if BrawlConfig.Roles[species.Role] then species.Role else "Fighter"
					local maxHp = BrawlConfig.Roles[role].Hp
					local unit = {
						Owner = owner,
						Index = item.Slot,
						BrainrotId = "sim" .. item.Slot,
						Role = role,
						MaxHp = maxHp,
						Hp = maxHp,
						Cooldown = 0,
						Ko = false,
						Species = brainrot.Species,
						Spd = BrainrotStats.get(brainrot).Spd,
					}
					BrawlSkills.attach(unit, brainrot.Passive, 0, ArtifactConfig.effectsOf(brainrot), brainrot.Stars)
					table.insert(units, unit)
				end

				local pending = {}
				clock.pending = pending
				clock.now = 0
				BrawlSkills.onArrive(ctx, units)
				local dt = BrawlConfig.Tick
				local tickAt = 0
				while true do
					-- Próxima coisa: um task.delay (golpes seguidos, Za Warudo) ou o próximo tick de 0,1 s
					local nextIndex, nextAt = nil, tickAt
					for i, job in pending do
						if job.At < nextAt then
							nextIndex, nextAt = i, job.At
						end
					end
					if nextAt >= duration then
						break
					end
					clock.now = nextAt
					if nextIndex then
						local job = table.remove(pending, nextIndex)
						job.Fn(table.unpack(job.Args, 1, job.Args.n))
					else
						local now = tickAt
						for _, unit in units do
							unit.Hitting = false
							unit.Cooldown -= dt
							BrawlSkills.tick(ctx, unit, dt, now)
							if not unit.Ko and not BrawlSkills.isStunned(unit, now) and unit.Cooldown <= 0 then
								BrawlSkills.bagAttack(ctx, unit, now, function(multiplier: number, basic: boolean)
									onHit(unit, multiplier, basic)
								end)
							end
						end
						tickAt += dt
					end
				end
				BrawlSkills.forget(owner)
				totalSum += runDamage
				best = math.max(best, runDamage)
				worst = math.min(worst, runDamage)
			end)
			clock.now, clock.pending = nil, nil
			if not ok then
				failures += 1
				firstError = firstError or tostring(err)
			end
		end

		local done = runs - failures
		local units = {}
		for _, item in entries do
			local row = perUnit[item.Slot]
			for _, field in { "Total", "Basic", "Skill", "Goes", "Jakalopita", "Hits" } do
				row[field] = math.floor(row[field] / math.max(1, done) + 0.5)
			end
			row.Dps = math.floor(row.Total / duration + 0.5)
			table.insert(units, row)
		end
		local average = totalSum / math.max(1, done)
		return {
			Mode = "Pinata",
			Runs = done,
			Failures = failures,
			Error = if done == 0 then firstError else nil,
			Sample = if firstError then { Error = firstError } else nil,
			Duration = duration,
			Reduction = reduction,
			Total = math.floor(average + 0.5),
			Best = math.floor(best + 0.5),
			Worst = if done > 0 then math.floor(worst + 0.5) else 0,
			Dps = math.floor(average / duration + 0.5),
			Goal = config.GoalDamage,
			Goals = math.floor(average / config.GoalDamage),
			Units = units,
		}
	end

	local function run(input: any)
		if input.Mode == "Pinata" then
			return runPinata(input)
		end
		return runFights(input)
	end

	return { data = dumpData, run = run }
end
]=]
local hostLoad = ...
local function load(source, name, env)
	if hostLoad then
		return hostLoad(source, name, env)
	end
	-- No navegador o luau-web não tem loadstring: a página passa o compilador dele como __compile
	local compile = __compile or loadstring
	local fn, err = compile(source, name)
	if not fn then
		error(err)
	end
	setfenv(fn, setmetatable(env, { __index = getfenv(1) }))
	return fn
end
local function tool(name)
	return load(SOURCES["tools/" .. name], name, {})()
end

local Runtime = tool("runtime")
local Polyfill = tool("polyfill")
local Json = tool("json")
local makeSim = tool("simcore")

local files, dirs = {}, {}
for path in SOURCES do
	if string.sub(path, 1, 4) == "src/" then
		files[path] = true
		local dir, name = string.match(path, "^(.*)/([^/]+)$")
		while dir do
			local list = dirs[dir]
			if not list then
				list = {}
				dirs[dir] = list
			end
			if not table.find(list, name) then
				table.insert(list, name)
			end
			name = string.match(dir, "([^/]+)$")
			dir = string.match(dir, "^(.*)/[^/]+$")
		end
	end
end

local globals = {}
for key, value in Polyfill do
	globals[key] = value
end
local runtime = Runtime.new({
	files = files,
	dirs = dirs,
	read = function(path)
		return SOURCES[path]
	end,
	load = load,
	globals = globals,
})
local Sim = makeSim(runtime.require, runtime.clock)

-- call("data") / call("run", textoJSON) → texto JSON (erro vira { Error = ... })
return function(command, text)
	local ok, result = pcall(function()
		if command == "data" then
			return Sim.data()
		elseif command == "run" then
			return Sim.run(Json.decode(text))
		end
		return { Error = "comando desconhecido: " .. tostring(command) }
	end)
	if not ok then
		return Json.encode({ Error = tostring(result) })
	end
	return Json.encode(result)
end