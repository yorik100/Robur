--[[
  KappaJinx

  Credits: wxx
]]

module("KappaJinx", package.seeall, log.setup)
clean.module("KappaJinx", package.seeall, log.setup)

-- Globals
local CoreEx = _G.CoreEx
local Libs = _G.Libs

local Menu = Libs.NewMenu
local Prediction = Libs.Prediction
local Orbwalker = Libs.Orbwalker
local CollisionLib = Libs.CollisionLib
local DamageLib = Libs.DamageLib
local ImmobileLib = Libs.ImmobileLib
local SpellLib = Libs.Spell
local TargetSelector = Libs.TargetSelector
local HealthPrediction = Libs.HealthPred

local ObjectManager = CoreEx.ObjectManager
local EventManager = CoreEx.EventManager
local Input = CoreEx.Input
local Enums = CoreEx.Enums
local Game = CoreEx.Game
local Geometry = CoreEx.Geometry
local Renderer = CoreEx.Renderer

local SpellSlots = Enums.SpellSlots
local SpellStates = Enums.SpellStates
local BuffTypes = Enums.BuffTypes
local Events = Enums.Events
local HitChance = Enums.HitChance
local HitChanceStrings = { "Collision", "OutOfRange", "VeryLow", "Low", "Medium", "High", "VeryHigh", "Dashing", "Immobile" };

local LocalPlayer = ObjectManager.Player.AsHero


-- Check if we are using the right champion
if LocalPlayer.CharName ~= "Jinx" then return false end

-- Globals
local Jinx = {}
local Utils = {}

Jinx.TargetSelector = nil
Jinx.Logic = {}

-- Spells
Jinx.Q = SpellLib.Active({
  Slot = SpellSlots.Q,
  Range = 900, -- this is just here to ensure GetTarget return a target at the right time
  UseHitbox = true
})

Jinx.W = SpellLib.Skillshot({
  Slot = SpellSlots.W,
  Range = 1500,
  Radius = 60,
  Speed = 3300,
  Delay = 0.4,
  Collisions = { Heroes = true, Minions = true, WindWall = true },
  UseHitbox = true,
  Type = "Linear"
})

Jinx.E = SpellLib.Skillshot({
  Slot = SpellSlots.E,
  Range = 900,
  Radius = 57,
  Speed = 1750,
  Delay = 0.5,
  Collisions = { Heroes = true, WindWall = true },
  Type = "Circular",
  IsTrap = true
})

Jinx.R = SpellLib.Skillshot({
  Slot = SpellSlots.R,
  Range = math.huge,
  Radius = 140,
  Speed = 1500,
  Delay = 0.6,
  Collisions = { Heroes = true, WindWall = true },
  Type = "Linear",
  UseHitbox = true
})

Jinx.R.GetDamage = function (Target, Surrounding)
  local Level = Jinx.R:GetLevel()
  local BaseDamage = ({ 250, 350, 450 })[Level]
  local BonusDamage = LocalPlayer.FlatPhysicalDamageMod * 1.5
  local MissHealthDamage = (Target.MaxHealth - Target.Health) * ({ 0.25, 0.30, 0.35 })[Level]
  local RawDamage = BaseDamage + BonusDamage + MissHealthDamage
  if Surrounding then
    RawDamage = RawDamage * 0.8
  end
  return DamageLib.CalculatePhysicalDamage(LocalPlayer, Target, RawDamage)
end
function HasStatik()
    for key, item in pairs(LocalPlayer.Items) do
        if item and (item.ItemId == 3094) then
            return true
        end
    end
    return false
end
local statikBuff = LocalPlayer:GetBuff("itemstatikshankcharge")

function Utils.IsGameAvailable()
  -- Is game available to automate stuff
  return not (Game.IsChatOpen() or Game.IsMinimized() or LocalPlayer.IsDead)
end

function Utils.IsInRange(From, To, Min, Max)
  -- Is Target in range
  local Distance = From:Distance(To)
  return Distance > Min and Distance <= Max
end

function Utils.GetBoundingRadius(Target)
  if not Target then return 0 end

  -- Bounding boxes
  return LocalPlayer.BoundingRadius + Target.BoundingRadius
end

function Utils.GetTrueMiniGunRange(Target)
  -- Calculate mini gun range
  if (HasStatik() and statikBuff) and (statikBuff.Count == 100) then
	return 525 + 150 + Utils.GetBoundingRadius(Target)
  else
	return 525 + Utils.GetBoundingRadius(Target)
  end
end

function Utils.GetTrueBazookaRange(Target)
  -- Calculate bazooka range
  local BonusRange = 0

  if Jinx.Q:IsLearned() then
    BonusRange = ({ 100, 125, 150, 175, 200 })[Jinx.Q:GetLevel()]
  end
  if (HasStatik() and statikBuff) and (statikBuff.Count == 100) then
	return 525 + math.min(525*0.35, 150) + Utils.GetBoundingRadius(Target)
  else
	return 525 + Utils.GetBoundingRadius(Target)
  end
  return Utils.GetTrueMiniGunRange(Target) + BonusRange
end

function Utils.IsValidTarget(Target)
  return Target and Target.IsTargetable and Target.IsAlive
end

function Utils.TargetsInRange(Target, Range, Team, Type, Condition)
  -- return target in range
  local Objects = ObjectManager.Get(Team, Type)
  local Array = {}
  local Index = 0

  for _, Object in pairs(Objects) do
    if Object and Object ~= Target then
      Object = Object.AsAI
      if
        Utils.IsValidTarget(Object) and
        (not Condition or Condition(Object))
      then
        local Distance = Target:Distance(Object.Position)
        if Distance <= Range then
          Array[Index] = Object
          Index = Index + 1
        end
      end
    end
  end

  return { Array = Array, Count = Index }
end

function Utils.IsRareMinion(Target)
  Target = Target.AsMinion
  if
    Target.IsDragon or
    Target.IsBaron
  then
    return true
  end

  return false
end

function Jinx.Logic.CalculateData()
  -- Get Q state
  Jinx.Q.IsActive = LocalPlayer:GetBuff("JinxQ")

  -- Get W delay
  Jinx.W.Delay = 0.6 - (0.02 * (((LocalPlayer.AttackSpeedMod - 1) * 100) / 25))
end

function Jinx.Logic.Q(Target, EnableOutOfRange, EnableMinHit, MinHitCount, ChaseMode)
  if not EnableOutOfRange and not EnableMinHit then return false end
  if not Jinx.Q:IsReady() then return false end

  if not Utils.IsValidTarget(Target) then
    if Jinx.Q.IsActive then
      return Jinx.Q:Cast()
    end
    return false
  end

  Target = Target.AsAI

  local MiniGunRange = Utils.GetTrueMiniGunRange(Target)
  local BazookaRange = math.huge

  if not ChaseMode then
    BazookaRange = Utils.GetTrueBazookaRange(Target)
  end

  local InRange = Utils.IsInRange(LocalPlayer.Position, Target.Position, MiniGunRange, BazookaRange)

  local IsOutOfRange =
    (InRange and not Jinx.Q.IsActive) or
    (not InRange and Jinx.Q.IsActive)

  local HasEnoughTargets =
    EnableMinHit and
    Utils.TargetsInRange(Target, 250, "enemy", "heroes").Count + 1 >= MinHitCount

  local XTarget =
    (not HasEnoughTargets and Jinx.Q.IsActive) or
    (HasEnoughTargets and not Jinx.Q.IsActive)

  if
    (EnableOutOfRange and IsOutOfRange and not HasEnoughTargets) or
    (EnableMinHit and XTarget and HasEnoughTargets)
  then
      return Jinx.Q:Cast()
  end

  return false
end

function Jinx.Logic.W(Target, Hitchance, Enable, EnableSmartRange)
  if not Enable then return false end
  if not Jinx.W:IsReady() then return false end
  if not Utils.IsValidTarget(Target) then return false end

  Target = Target.AsAI

  local BazookaRange = Utils.GetTrueBazookaRange(Target)

  if
    (EnableSmartRange and Utils.IsInRange(LocalPlayer.Position, Target.Position, BazookaRange, math.huge)) or
    (not EnableSmartRange)
  then
    return Jinx.W:CastOnHitChance(Target, Hitchance)
  end

  return false
end

function Jinx.Logic.E(Target, Hitchance, Enable)
  if not Enable then return false end
  if not Jinx.E:IsReady() then return false end
  if not Utils.IsValidTarget(Target) then return false end

  Target = Target.AsAI

  return Jinx.E:CastOnHitChance(Target, Hitchance)
end

function Jinx.Logic.R(Target, Hitchance, TravelTime, Enable, MinRange, MaxRange)
  if not Enable then return false end
  if not Jinx.R:IsReady() then return false end

  local KillStealDelta  = HealthPrediction.GetKillstealHealth(Target, TravelTime, Enums.DamageTypes.Physical) - Target.Health
  local HealthPredicted = HealthPrediction.GetHealthPrediction(Target, TravelTime) + KillStealDelta

  if
    Utils.IsInRange(LocalPlayer.Position, Target.Position, MinRange, MaxRange) and
    Jinx.R.GetDamage(Target, false) > HealthPredicted and HealthPredicted > 0
  then
    return Jinx.R:CastOnHitChance(Target, Hitchance)
  end

  return false
end

function Jinx.Logic.RKS(Target, TravelTime, Enable)
  if not Enable then return false end
  if not Jinx.R:IsReady() then return false end

  local EffectRadius = Jinx.R:GetLevel() > 1 and 1000 or 400

  local RareMinionInRange = Utils.TargetsInRange(Target, EffectRadius, "neutral", "minions", Utils.IsRareMinion)

  if RareMinionInRange.Count <= 0 then return false end

  local Minion = RareMinionInRange.Array[0]

  if not Minion or not Utils.IsValidTarget(Minion) then return false end

  local HealthPredicted = HealthPrediction.GetHealthPrediction(Minion, TravelTime)
  
  if Jinx.R.GetDamage(Minion, true) > HealthPredicted and HealthPredicted > 0 then
    return Jinx.R:CastOnHitChance(Target, HitChance.VeryLow)
  end
end

function Jinx.Logic.Combo()
  if Orbwalker.IsWindingUp() then
      return
  end
  local Target = Orbwalker.GetTarget()

  if Jinx.Logic.Q(Jinx.Q:GetTarget(), Menu.Get("Combo.Q.OutOfRange"), Menu.Get("Combo.Q.MinHit"), Menu.Get("Combo.Q.MinHitCount"), true) then return true end
  if Jinx.Logic.W(Target or Jinx.W:GetTarget(), Menu.Get("Combo.W.HitChance"), Menu.Get("Combo.W.Use"), Menu.Get("Combo.W.SmartRange")) then return true end
  if Jinx.Logic.E(Target or Jinx.E:GetTarget(), Menu.Get("Combo.E.HitChance"), Menu.Get("Combo.E.Use")) then return true end

  return false
end

function Jinx.Logic.Harass()
  if Orbwalker.IsWindingUp() then
      return
  end
  if (LocalPlayer.Mana / LocalPlayer.MaxMana < (Menu.Get("Harass.ManaSave") / 100)) then
    if Jinx.Q.IsActive then
      if Jinx.Q:Cast() then return false end
    end
    return false
  end

  local Target = Orbwalker.GetTarget()

  if Jinx.Logic.Q(Jinx.Q:GetTarget(), Menu.Get("Harass.Q.OutOfRange"), Menu.Get("Harass.Q.MinHit"), Menu.Get("Harass.Q.MinHitCount"), false) then return true end
  if Jinx.Logic.W(Target or Jinx.W:GetTarget(), Menu.Get("Harass.W.HitChance"), Menu.Get("Harass.W.Use"), Menu.Get("Harass.W.SmartRange")) then return true end

  return false
end

function Jinx.Logic.Waveclear()
  if Orbwalker.IsWindingUp() then
      return
  end
  if Jinx.Q.IsActive then
    if Jinx.Q:Cast() then return false end
  end

  return false
end

function Jinx.Logic.Auto()
  local Targets = ObjectManager.Get("enemy", "heroes")

  for _, Target in pairs(Targets) do
    if Target then
      Target = Target.AsHero

      if Utils.IsValidTarget(Target) then     
        if Jinx.Logic.E(Target, HitChance.Immobile, Menu.Get("Auto.E.Immobilized")) then return true end
        if Jinx.Logic.E(Target, HitChance.Dashing, Menu.Get("Auto.E.Gapclose")) then return true end
        
        local Distance = LocalPlayer:EdgeDistance(Target.Position)
        Jinx.R.Speed = Distance > 1300 and (1300 * 1700 + ((Distance - 1300) * 2200)) / Distance or 1700
        local TravelTime = (Jinx.R.Delay + Distance / Jinx.R.Speed) - (Game.GetLatency() / 1000)

        local MinRange = Menu.Get("Auto.R.SmartRange") and Utils.GetTrueBazookaRange(Target) or 0
        local MaxRange = Menu.Get("Auto.R.SmartRange") and 5000 or math.huge

        if Jinx.Logic.R(Target, Menu.Get("Auto.R.HitChance"), TravelTime, Menu.Get("Auto.R.Use"), MinRange, MaxRange) then return true end
        if Jinx.Logic.RKS(Target, TravelTime, Menu.Get("Auto.R.KsRare")) then return true end
      end
    end
  end

  return false
end

function Jinx.LoadMenu()
  Menu.RegisterMenu("KappaJinx", "KappaJinx", function ()
    Menu.ColumnLayout("Casting", "Casting", 2, true, function ()
      Menu.ColoredText("Combo", 0xB65A94FF, true)
      Menu.ColoredText("> Q", 0x0066CCFF, false)
      Menu.Checkbox("Combo.Q.OutOfRange", "When Out Of Range", true)
      Menu.Checkbox("Combo.Q.MinHit", "If Can Hit", true)
      Menu.Slider("Combo.Q.MinHitCount", "X Targets", 3, 1, 5, 1)
      Menu.ColoredText("> W", 0x0066CCFF, false)
      Menu.Checkbox("Combo.W.Use", "Use", true)
      Menu.Dropdown("Combo.W.HitChance", "HitChance", 5, HitChanceStrings)
      Menu.Checkbox("Combo.W.SmartRange", "Smart Range", true)
      Menu.ColoredText("> E", 0x0066CCFF, false)
      Menu.Checkbox("Combo.E.Use", "Use", true)
      Menu.Dropdown("Combo.E.HitChance", "HitChance", 6, HitChanceStrings)
      Menu.NextColumn()
      
      Menu.ColoredText("Harass", 0xB65A94FF, true)
      Menu.Slider("Harass.ManaSave", "Mana Save", 65, 0, 100, 1)
      Menu.ColoredText("> Q", 0x0066CCFF, false)
      Menu.Checkbox("Harass.Q.OutOfRange", "When Out Of Range", true)
      Menu.Checkbox("Harass.Q.MinHit", "When Can Hit", true)
      Menu.Slider("Harass.Q.MinHitCount", "X Targets", 3, 1, 5, 1)
      Menu.ColoredText("> W", 0x0066CCFF, false)
      Menu.Checkbox("Harass.W.Use", "Use", true)
      Menu.Dropdown("Harass.W.HitChance", "HitChance", 6, HitChanceStrings)
      Menu.Checkbox("Harass.W.SmartRange", "Smart Range", true)
    end)
    Menu.Separator()
    Menu.ColumnLayout("Drawings", "Drawings", 3, true, function ()
      Menu.ColoredText("Auto", 0xB65A94FF, true)
      Menu.ColoredText("> E", 0x0066CCFF, false)
      Menu.Checkbox("Auto.E.Gapclose", "Gapclose", true)
      Menu.Checkbox("Auto.E.Immobilized", "Immobilized", true)
      Menu.ColoredText("> R", 0x0066CCFF, false)
      Menu.Checkbox("Auto.R.Use", "Use", true)
      Menu.Checkbox("Auto.R.SmartRange", "Smart Range", true)
      -- Menu.Slider("Auto.R.MinRange", "Min Range", 925, 0, 3000, 100)
      -- Menu.Slider("Auto.R.MaxRange", "Max Range", 4000, 3000, 50000, 100)
      Menu.Dropdown("Auto.R.HitChance", "HitChance", 6, HitChanceStrings)
      Menu.Checkbox("Auto.R.KsRare", "KS Drake/Baron", true)
      Menu.NextColumn()

      Menu.ColoredText("Drawings", 0xB65A94FF, true)
      Menu.Checkbox("Drawings.W", "W", true)
      Menu.Checkbox("Drawings.E", "E", true)
	  Menu.Checkbox("Drawings.Q", "Q", true)
    end)
  end)
end

function Jinx.OnDraw()
  -- If player is not on screen than don't draw
  -- if not LocalPlayer.IsOnScreen then return false end;

  -- Get spells ranges
  local Spells = { W = Jinx.W, E = Jinx.E }

  -- Draw them all
  for k, v in pairs(Spells) do
    if Menu.Get("Drawings." .. k) then
        Renderer.DrawCircle3D(LocalPlayer.Position, v.Range, 30, 1, 0xFFFFFFFF)
    end
  end
  if Menu.Get("Drawings.Q") then
	if LocalPlayer:GetBuff("JinxQ") then
		QRange = 625
	else
		if Jinx.Q:IsLearned() then
			QRange = 625 + ({ 100, 125, 150, 175, 200 })[Jinx.Q:GetLevel()]
		else
			QRange = 725
		end
	end
	if (HasStatik() and statikBuff) and (statikBuff.Count == 100) then
		QRange = QRange + math.min(QRange*0.35, 150)
	end
    Renderer.DrawCircle3D(LocalPlayer.Position, QRange, 30, 1, 0xFF0000FF)
  end

  return true
end

function Jinx.OnTick()

  -- Check if game is available to do anything
  if not Utils.IsGameAvailable() then return false end

  -- Get current orbwalker mode
  local OrbwalkerMode = Orbwalker.GetMode()

  -- Get the right logic func
  local OrbwalkerLogic = Jinx.Logic[OrbwalkerMode]

  -- Do we have a callback for the orbwalker mode?
  if OrbwalkerLogic then
    -- Calculate spell data
    Jinx.Logic.CalculateData()

    -- Do logic
    if OrbwalkerLogic() then return true end
  end

  if Jinx.Logic.Auto() then return true end

  return false
end

function OnLoad()
  -- Load our menu
  Jinx.LoadMenu()

  -- Load our target selector
  Jinx.TargetSelector = TargetSelector()

  -- Register callback for func available in champion object
  for EventName, EventId in pairs(Events) do
    if Jinx[EventName] then
        EventManager.RegisterCallback(EventId, Jinx[EventName])
    end
  end

  INFO("> You are using KappaJinx !")

	return true
end
