--[[ Engine controller - keeps X number of engines in the system
     Created for the Youtube channel https://youtube.com/user/nzHook 2018
     myRail Episode Showing Usage: https://www.youtube.com/watch?v=02_GhpYRju4
     
    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.
    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
]]--
local component = require("component")
local os = require("os")
local event = require("event")
local sides = require("sides")
local colors = require("colors")
local computer = require("computer")
local serialization = require("serialization")
local filesystem = require("filesystem")
local term = require("term")


-- CHANGE THIS: This is the redstone IO taht is primary
--    there is no garentuee that OC will detect this correctly each boot
local rsid = "447"

-- rsmax is the starting point for the number calcs, eg. if the redstone io is 1 block away then any signal for white
--   would be 15 - 1. so this value should be 14
--   NOTE: Vanilla goes to 15, this code works in base 10, so you can have a maximum of 5 blocks between
local rsmax = 14

-- Tasks, indexed by their name
---  NOTE: As of writing there is no way to check what a tickets destination is
---    hence the requirement for the slot number. 
--  TODO: Check if the same slot number appears twice and fatal
local tasks = {}
tasks["WoodyTreeTransport"] = {slot = 1, required = 0}
tasks["WaterviewLine"] = {slot = 2, required = 0}
tasks["CharcoalHillCharcoal"] = {slot = 3, required = 0}
tasks["XMasLine"] = {slot = 4, required = 0}

-- Redstone colour maps
colors.release = colors.lightblue                     -- Transposer release
colors.blockentry = colors.magenta                    -- Locking track at the entry
colors.enterdepot = colors.white                      -- Switch motor for Depot
colors.depotexit = colors.yellow                      -- Locking track at the exit of the depot
colors.blockinuse = colors.orange                     -- Track in use (from block signal)

-- Debugging of the redstone
colors.rs = {}
colors.rs[0] = colors.white
colors.rs[1] = colors.orange
colors.rs[2] = colors.magenta
colors.rs[3] = colors.lightblue
colors.rs[4] = colors.yellow

-- The sides of the transposer
local side_train = sides.back
local side_chest = sides.front
-- The slot in the train to put the ticket
--   in a steam engine this should be 4, in a creative its slot 1
-- TODO: Autodetect
local slot_train = 1
local slot_chest = nil

-- The port that we listen on for updates - should be unique
local comms_port = 1234
-- rcomm is the port we send our comms back (nothing yet)
local rcomms_port = 1235

-- Internal vars
local nextstatecheck = 0
local engines = {}
local defaultchecktimeout = 10
local checktimeout = defaultchecktimeout
local runstate = 1


local oldprint = print
local log = {}
local function print(...)
    -- We track previous messages to show in the GUI
    for x = 1, 9 do
        log[x] = log[x + 1]
    end
    log[10] = table.pack(...)
--    oldprint(...)
end

local function draw_gui()
  local curx, cury = term.getCursor()
  term.setCursor(1, 1)
  term.clearLine()
  oldprint("==================================")
  for k, v in pairs(tasks) do
    term.clearLine()
    oldprint(k, v.current .. "/" .. v.required)
  end
  term.clearLine()
  oldprint("==================================")
  for x = 1, 10 do
    term.clearLine()
    if log[x] then
      oldprint(table.unpack(log[x]))
    end
  end
  term.setCursor(curx, cury)
end


local function engine_num(currentB, currentT) 
  -- If you need more than 100 trains, you could change the 10 upto 16 HOWEVER remember the detectors
  --   can only work out upto *15 colors
  -- We add 1 so that we start the train count at 1 (white, white = 1 not 0)
  return (currentB * 10) + currentT + 1
end

local function nextrain()
  if component.redstone.getBundledInput(sides.bottom, colors.blockinuse) > 0 then       -- Double check we dont let something in
    print("Call in the next train")
    component.redstone.setBundledOutput(sides.bottom, colors.release, 0)              -- Release
    component.redstone.setBundledOutput(sides.bottom, colors.blockentry, 15000)       -- Entry
    component.redstone.setBundledOutput(sides.bottom, colors.enterdepot, 0)           -- Depot
    component.redstone.setBundledOutput(sides.bottom, colors.depotexit, 0)
    checktimeout = defaultchecktimeout
  end
end

-- Find an appropriate task
--  currenttask is the current task being done by the engine (nil to indicate no current task)
local function find_task(currenttask)
      -- If the engine is fine doing its currenttask then it can keep doing it
      if currenttask and tasks[currenttask].current <= tasks[currenttask].required then
        print("keeping", currenttask, tasks[currenttask].current, "/", tasks[currenttask].required)
        return currenttask
      end
      -- Could just detect the first task that is required and return
      --  but if there are not enough engines available something else may suffer
      --  so we find the task with the least amount of engines
      --  TODO Should we make it percetage based (eg. a task needing 100 engines still takes prioity of a task needing 10)
      local returntask = nil
      local returntaskcount = math.huge
      for k, v in pairs(tasks) do
        print(k, v.current, "of", v.required, " ?>> ", returntaskcount)
        if v.current < v.required and v.current < returntaskcount then
          returntask = k
          returntaskcount = v.current
        end
      end
      
      print("Returning ", returntask)
      if returntask then
        tasks[returntask].current = tasks[returntask].current + 1
      end
      if currenttask then
        tasks[currenttask].current = tasks[currenttask].current - 1
      end
      return returntask
end

local function state_check()
  nextstatecheck = computer.uptime() + 5
  
  -- Reset the current counters in case they have got out of sync?
  for k, v in pairs(tasks) do
    tasks[k].current = 0
  end

  local ignorebefore = computer.uptime() - 3600
  for k, v in pairs(engines) do
    -- Ignore any engine that hasnt been seen for a while
    if v.lastseen < ignorebefore then
      print("Havnt seen " .. k .. " for a while, I hope its alright? I'll add another train")
    else
      if v.task then
        tasks[v.task].current = tasks[v.task].current + 1
      end
    end
  end

  -- Do we have enough active locos? if not release the depot
  --  We only release one train each state check. This could be a slow ramp up
  --  but it shouldnt be required too often
  for k, v in pairs(tasks) do
    if tasks[k].current < tasks[k].required then
      print("Releasing a train from the depot to meet demand")
      component.redstone.setBundledOutput(sides.bottom, colors.depotexit, 15)
      os.sleep(0.2)
      component.redstone.setBundledOutput(sides.bottom, colors.depotexit, 0)
      -- Recheck earlier if we need more than 1
      if tasks[k].current + 1 < tasks[k].required then
        nextstatecheck = computer.uptime() + 2
      end
      break;
    end
  end
end


-- Setup the components
component.setPrimary("redstone", component.get(rsid))
component.modem.open(comms_port)


-- Load previous state
if filesystem.exists("/home/engine.states") then
  local f = io.open("/home/engine.states", "r")
  engines = serialization.unserialize(f:read("*all"))
  f:close()
  print("Loaded engines")
end

-- Ok, lets get started
for k, v in pairs(engines) do
  engines[k].lastseen = computer.uptime()
end 

state_check()
nextrain()
while runstate > 0 do
  local e, a1, a2, a3, a4, a5, a6, a7 = event.pull(checktimeout)
  
  if not e then
    -- Its the timeout, we can ignore this
    --  Dont put anything here since we may never get here in a busy depot
  elseif e == "key_down" then
    if a2 == 113 then       -- q exits
      print("Ending program - waiting for current loco to clear")
      runstate = 2
    elseif a2 == 114 then   -- r manually releases an engine
      print("Releasing engine from depot")
      component.redstone.setBundledOutput(sides.bottom, colors.depotexit, 15)
--      os.sleep(0.2)
      component.redstone.setBundledOutput(sides.bottom, colors.depotexit, 0)
    else
      print("Unknown keypress ", a2, a3)
    end
  elseif e == "redstone_changed" then
    if component.isPrimary(a1) then
      -- If its out control redstone then it will a train entering or exiting
      if component.redstone.getBundledInput(sides.bottom, colors.blockinuse) > 0 then
        -- if runstate is not 1 then we are in exit mode, and waiting for this event so we can change to 0 now
        if runstate == 1 then
          nextrain()
        else
          runstate = 0
        end
      else
        -- print("Inbound train")
        component.redstone.setBundledOutput(sides.bottom, colors.blockentry, 0)       -- Block entry
      end
    else
      -- Its the detector, track the train type. We can also assume that if these are fireing
      --   a loco is on its way in so we increase how often we check
      if sides[a2] == "top" and a4 > 0 then
        -- This indicates the train has poast the detector
        checktimeout = 0.3
        if not currentT or not currentB then
          -- We couldnt determine a colour? send it to the depot
          slot_chest = nil
          currentT = -1
          currentB = -1
          computer.beep(500, 0.2);
          computer.beep(200, 0.2);
        else
          print("Its #", engine_num(currentB, currentT), currentB .. " bottom", currentT .. " top")
          print("Its #", engine_num(currentB, currentT), colors[colors.rs[currentB]] .. " bottom", colors[colors.rs[currentT]] .. " top")
          
          local engineid = engine_num(currentB, currentT)
          if engines[engineid] then
            print("I have seen this one its doing ", engines[engineid].task)
            engines[engineid].task = find_task(engines[engineid].task)
            engines[engineid].lastseen = computer.uptime()
          else
            print("New engine")
            engines[engineid] = {}
            engines[engineid].lastseen = computer.uptime()
            engines[engineid].task = find_task()
          end
          
          local tmpf = io.open("/home/engine.states", "w")
          local tmpi = serialization.serialize(engines)
          tmpf:write(tmpi)
          tmpf:close()
          
          if engines[engineid].task then
            slot_chest = tasks[engines[engineid].task].slot
          else
            slot_chest = nil
          end
        end
      elseif sides[a2] == "back" and a3 == 0 then
        currentB = rsmax - a4
      elseif sides[a2] == "front" and a3 == 0 then
        currentT = rsmax - a4
      end
    end
  
    -- Do other stuff here
    
  else
      print("Unknown " .. e, a1, a2, a3, a4, a5, a6, a7)
  end

  -- It would be nice if OpenComputers fired an inventoryChanged event
  --   then we could wait for a longer time. But for now we check on every loop
  --   for an inventroy in front of the transposer
  if component.transposer.getInventorySize(side_train) and currentT and currentB then
    component.redstone.setBundledOutput(sides.bottom, colors.release, 0)
    if slot_chest then
      component.transposer.transferItem(side_chest, side_train, slot_train, slot_chest)
      --os.sleep(1)
      component.transposer.transferItem(side_train, side_chest, slot_chest, slot_train)
    else
      -- Nothing to do, send to depot
      component.redstone.setBundledOutput(sides.bottom, colors.enterdepot, 15)
    end
    checktimeout = defaultchecktimeout

    -- trigger the train to move
    component.redstone.setBundledOutput(sides.bottom, colors.release, 15)
    currentT = nil
    currentB = nil
  end
  
  if computer.uptime() > nextstatecheck then
    print("STATE CHECK")
    state_check()
  end
  
  draw_gui()
end

-- If we get to the end block entry
component.redstone.setBundledOutput(sides.bottom, colors.blockentry, 0)       -- Block entry