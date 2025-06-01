--[[***********************************************************************
*   Copyright 2021 Andreas Wendler                                        *
*   Robotics Erlangen e.V.                                                *
*   http://www.robotics-erlangen.de/                                      *
*   info@robotics-erlangen.de                                             *
*                                                                         *
*   This program is free software: you can redistribute it and/or modify  *
*   it under the terms of the GNU General Public License as published by  *
*   the Free Software Foundation, either version 3 of the License, or     *
*   any later version.                                                    *
*                                                                         *
*   This program is distributed in the hope that it will be useful,       *
*   but WITHOUT ANY WARRANTY; without even the implied warranty of        *
*   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the         *
*   GNU General Public License for more details.                          *
*                                                                         *
*   You should have received a copy of the GNU General Public License     *
*   along with this program.  If not, see <http://www.gnu.org/licenses/>. *
*************************************************************************]]

local TrackedWorld = require "base/world"
local Metric = require "base/metric"
local TrueWorld = require "validation-rules/trueworld"
local LastTouch = require "validation-rules/lasttouch"

local GameEvents = require "gameevents"
local GameController = require "gamecontroller"

-- rules
-- local DoubleTouch = require "validation-rules/doubletouch"
local OutOfField = require "validation-rules/outoffield"
local FastShot = require "validation-rules/fastshot"
local FreekickDistance = require "validation-rules/freekickdistance"
local PlacementSuccess = require "validation-rules/placementsuccess"
local AttackerDefAreaDist = require "rules/attackerdefareadist"
local AttackerInDefenseArea = require "rules/attackerindefensearea"
local MultipleDefender = require "rules/multipledefender"
local PlacementInterference = require "rules/placementinterference"
local StopSpeed  = require "rules/stopspeed"
local Collision = require "rules/collision"

local EventValidator = {}

-- NOTE: if you add an event here, also add all the supported event types in the list below
local foulClasses = {
	-- DoubleTouch,
	OutOfField,
	FastShot,
	AttackerDefAreaDist,
	StopSpeed,
	AttackerInDefenseArea,
	PlacementInterference,
	MultipleDefender,
	FreekickDistance,
	PlacementSuccess,
	Collision
}
local fouls = nil

local SUPPORTED_EVENTS = {
	-- "ATTACKER_DOUBLE_TOUCHED_BALL",
	"BALL_LEFT_FIELD_GOAL_LINE",
	"BALL_LEFT_FIELD_TOUCH_LINE",
	"AIMLESS_KICK",
	"BOT_KICKED_BALL_TOO_FAST",
	"BOT_TOO_FAST_IN_STOP",
	"ATTACKER_TOO_CLOSE_TO_DEFENSE_AREA",
	"ATTACKER_TOUCHED_BALL_IN_DEFENSE_AREA",
	"BOT_INTERFERED_PLACEMENT",
	"DEFENDER_IN_DEFENSE_AREA",
	"DEFENDER_TOO_CLOSE_TO_KICK_POINT",
	"PLACEMENT_SUCCEEDED",
	"POSSIBLE_GOAL",
	"BOT_CRASH_DRAWN",
	"BOT_CRASH_UNIQUE"
}
-- still missing rules: double touch, dribbling, bug: aimless kick?

local foulTimes = {}
local FOUL_TIMEOUT = 3 -- minimum time between subsequent fouls of the same kind

local function runEvent(foul)
	-- take the referee state until the second upper case letter, thereby
	-- stripping 'Blue', 'Yellow', 'ColorPrepare', 'Force' and 'PlacementColor'
	local simpleRefState = TrueWorld.RefereeState:match("%u%l+")
	if foul.possibleRefStates[simpleRefState] and
			(foul.shouldAlwaysExecute or not foulTimes[foul] or TrueWorld.Time - foulTimes[foul] > FOUL_TIMEOUT) then
		local event = foul:occuring()
		if event then
			foulTimes[foul] = TrueWorld.Time

			EventValidator.dispatchValidationEvent(event)

			foul:reset()
		end
	elseif not foul.possibleRefStates[simpleRefState] then
		foul:reset()
	end
end

local waitingEvents = {
	tracked = {},
	validation = {}
}

local eventsThisFrame = {}

function EventValidator.sendEvent(event, fromTracked, fromValidation)
	log(GameEvents.eventMessage(event) .. " [" .. (fromTracked and "R" or "") .. ((fromTracked and fromValidation) and ", " or "") ..
		(fromValidation and "VR" or "") .. "]")
	GameController.sendEvent(event)
	eventsThisFrame[event.type] = true
end

function EventValidator.checkEvent(event, source)
	local otherSource = source == "tracked" and "validation" or "tracked"
	for time, oldEvent in pairs(waitingEvents[otherSource]) do
		if event.type == oldEvent.type then
			EventValidator.sendEvent(event, true, true)
			waitingEvents[otherSource][time] = nil
			return
		end
	end
	waitingEvents[source][TrueWorld.Time] = event
end

local EVENT_MATCH_TIMEOUT = 0.8
function EventValidator.checkEventTimeout()
	for _, source in ipairs({"tracked", "validation"}) do
		for time, event in pairs(waitingEvents[source]) do
			if TrueWorld.Time - time > EVENT_MATCH_TIMEOUT then
				log("<font color=\"red\">" .. "Event match timeout: " .. event.type .. "</font>")
				EventValidator.sendEvent(event, source == "tracked", source == "validation")
				waitingEvents[source][time] = nil
			end
		end
	end
end

local lastUpdateTime = nil
function EventValidator.dispatchEvent(event)
	if lastUpdateTime == nil or TrackedWorld.Time - lastUpdateTime > 1 then
		EventValidator.sendEvent(event, true, false)
		return
	end
	for _, type in ipairs(SUPPORTED_EVENTS) do
		if event.type == type then
			EventValidator.checkEvent(event, "tracked")
			return
		end
	end
	EventValidator.sendEvent(event, true, false)
end

function EventValidator.dispatchValidationEvent(event)
	EventValidator.checkEvent(event, "validation")
end

function EventValidator.update()
	TrueWorld.update()
	LastTouch.update()
	lastUpdateTime = TrueWorld.Time

	if fouls == nil then
		fouls = {}
		for _, foul in ipairs(foulClasses) do
			local inst = foul(TrueWorld)
			inst:reset()
			table.insert(fouls, inst)
		end
	end

	for _, foul in ipairs(fouls) do
		runEvent(foul)
	end

	EventValidator.checkEventTimeout()
end

local eventToFile = {
	["BOT_CRASH_DRAWN"] = "collision",
	["BOT_CRASH_UNIQUE"] = "collision",
	["BOT_KICKED_BALL_TOO_FAST"] = "fastshot",
	["BALL_LEFT_FIELD_GOAL_LINE"] = "outoffield",
	["BALL_LEFT_FIELD_TOUCH_LINE"] = "outoffield",
	["AIMLESS_KICK"] = "outoffield",
	["POSSIBLE_GOAL"] = "outoffield",
	["DEFENDER_IN_DEFENSE_AREA"] = "multipledefender",
	["BOT_DRIBBLED_BALL_TOO_FAR"] = "dribbling",
	["ATTACKER_TOUCHED_BALL_IN_DEFENSE_AREA"] = "attackerindefensearea",
	["BOT_TOO_FAST_IN_STOP"] = "stopspeed",
	["ATTACKER_TOO_CLOSE_TO_DEFENSE_AREA"] = "attackerdefareadist",
	["DEFENDER_TOO_CLOSE_TO_KICK_POINT"] = "freekickdistance",
	["ATTACKER_DOUBLE_TOUCHED_BALL"] = "doubletouch",
	["PLACEMENT_SUCCEEDED"] = "ballplacement",
	["BOT_INTERFERED_PLACEMENT"] = "placementinterference",
}

function EventValidator.createMetrics()
	for event, filename in pairs(eventToFile) do
		local foul = require("rules/" .. filename)()
		local simpleRefState = TrackedWorld.RefereeState:match("%u%l+")
		if (foul.runOnInvisibleBall or TrackedWorld.Ball:isPositionValid()) and foul.possibleRefStates[simpleRefState] then
			Metric.addMetric("autoref/" .. event, eventsThisFrame[event] and 1 or 0, TrackedWorld.TimeDiff)
		end
	end
	eventsThisFrame = {}
end

return EventValidator
