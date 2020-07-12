local obs = _G.obslua

local NUM_SOURCES = 3
local CURRENT_SCENE_OPTION = "[current scene]"
local triggered = false
local triggerCallback = nil
local cachedContents = nil
local cachedMatches = nil
local cachedSettings = {
  sources = {}
}
local utils = {}

-- scene should be a obs_scene_t, not a obs_source_t, i.e. call
-- obs_scene_from_source() before calling this
local function set_sources_visibility_in_scene(visibility, scene)
  -- use visibility of scene items instead of enabling/disabling sources
  -- because enabling/disabling sources is not exposed to the frontend AFAIK,
  -- so it's confusing for users (visible scene items don't show up for seemingly
  -- no reason)
  local sceneitems = obs.obs_scene_enum_items(scene)

  if sceneitems ~= nil then
    for _, sceneitem in ipairs(sceneitems) do
      local source = obs.obs_sceneitem_get_source(sceneitem)
      local name = obs.obs_source_get_name(source)
      if utils.in_array(cachedSettings.sources, name) then
        obs.obs_sceneitem_set_visible(sceneitem, visibility)
        obs.obs_source_set_enabled(source, true)
      end
    end
  end

  obs.sceneitem_list_release(sceneitems)
end

local function set_sources_visibility_in_all_scenes(visibility)
  local sceneSources = obs.obs_frontend_get_scenes()

  for _, sceneSource in ipairs(sceneSources) do
    local scene = obs.obs_scene_from_source(sceneSource)
    set_sources_visibility_in_scene(visibility, scene)
  end

  obs.source_list_release(sceneSources)
end

local function set_sources_visibility_in_current_scene(visibility)
  local sceneSource = obs.obs_frontend_get_current_scene()

  local scene = obs.obs_scene_from_source(sceneSource)
  set_sources_visibility_in_scene(visibility, scene)

  obs.obs_source_release(sceneSource)
end

local function set_sources_visibility_in_scene_with_name(visibility, sceneName)
  local sceneSources = obs.obs_frontend_get_scenes()

  for _, sceneSource in ipairs(sceneSources) do
    local name = obs.obs_source_get_name(sceneSource)
    if name == sceneName then
      local scene = obs.obs_scene_from_source(sceneSource)
      set_sources_visibility_in_scene(visibility, scene)
      break
    end
  end

  obs.source_list_release(sceneSources)
end

local function set_sources_visibility(visibility)
  if cachedSettings.allscenes then
    set_sources_visibility_in_all_scenes(visibility)
  elseif cachedSettings.scenechoice == CURRENT_SCENE_OPTION then
    set_sources_visibility_in_current_scene(visibility)
  else
    set_sources_visibility_in_scene_with_name(visibility, cachedSettings.scenechoice)
  end
end

local function reset()
  triggered = false
  obs.timer_remove(reset)

  set_sources_visibility(false)

  if triggerCallback then
    obs.timer_remove(triggerCallback)
    triggerCallback = nil
  end
end

local function trigger(duration)
  if duration then
    obs.timer_add(reset, duration*1000)
  end

  set_sources_visibility(true)
end

local function setup_trigger(duration)
  triggered = true
  local delay = cachedSettings.delay
  if delay > 0 then
    triggerCallback = function()
      trigger(duration)
      obs.timer_remove(triggerCallback)
      triggerCallback = nil
    end
    obs.timer_add(triggerCallback, delay)
  else
    trigger(duration)
  end
end

local function should_check()
  if cachedSettings.file == "" then
    return false
  end

  if triggered then
    return cachedSettings.contentsmatch
  end

  return not triggered
end

local function check_callback()
  if should_check() then
    local contents = utils.get_file_contents(cachedSettings.file)
    if contents == nil then
      return
    end
    local contentsChanged = contents ~= cachedContents

    if cachedSettings.anychange then
      if contentsChanged then
        setup_trigger(cachedSettings.duration)
      end
    elseif not cachedMatches or contentsChanged then
      local matches = contents:gsub("%s+$", ""):match(cachedSettings.contents)
      if matches and not cachedMatches then
        local duration = cachedSettings.duration
        if cachedSettings.contentsmatch then
          duration = nil
        end
        setup_trigger(duration)
      elseif not matches and triggered and cachedSettings.contentsmatch then
        reset()
      end
      cachedMatches = matches ~= nil
    end

    cachedContents = contents
  end
end

local function setup_check_callback(period)
  obs.timer_remove(check_callback)
  obs.timer_add(check_callback, period)
end

function utils.get_file_contents(file)
  local f, err = io.open(file, "r")
  if not f then
    return nil, err
  end
  local contents = f:read("*a")
  io.close(f)
  return contents
end

function utils.in_array(tbl, value)
  for _, v in ipairs(tbl) do
    if v == value then
      return true
    end
  end
  return false
end

local function reload()
  cachedContents = utils.get_file_contents(cachedSettings.file)
  cachedMatches = nil
  reset()
  check_callback()
  setup_check_callback(cachedSettings.triggerperiod)
end

-- script_update gets called before modified callbacks, so cachedSettings gets updated there
-- and we can use this as the modified callback
local function checkboxes_update(props)
  local anychange = cachedSettings.anychange
  local contentsmatch = cachedSettings.contentsmatch

  local contentsProp = obs.obs_properties_get(props, "contents")
  local contentsmatchProp = obs.obs_properties_get(props, "contentsmatch")
  local durationProp = obs.obs_properties_get(props, "duration")
  obs.obs_property_set_enabled(contentsProp, not anychange)
  obs.obs_property_set_enabled(contentsmatchProp, not anychange)
  obs.obs_property_set_enabled(durationProp, not contentsmatch or anychange)

  local allscenes = cachedSettings.allscenes

  local scenechoiceProp = obs.obs_properties_get(props, "scenechoice")
  obs.obs_property_set_enabled(scenechoiceProp, not allscenes)

  -- return true to update property widgets
  return true
end

----------------------------------------------------------

-- A function named script_properties defines the properties that the user
-- can change for the entire script module itself
function _G.script_properties()
  local props = obs.obs_properties_create()
  obs.obs_properties_add_path(props, "file", "File to check", obs.OBS_PATH_FILE, nil, nil)
  obs.obs_properties_add_int(props, "triggerperiod", "Trigger check period\n(milliseconds)", 0, 100000, 100)

  local anychange = obs.obs_properties_add_bool(props, "anychange", "Trigger on any change in file contents")
  obs.obs_property_set_modified_callback(anychange, checkboxes_update)

  local contents = obs.obs_properties_add_text(props, "contents", "Trigger when file\ncontents match pattern", obs.OBS_TEXT_DEFAULT)
  obs.obs_property_set_long_description(contents, "Uses Lua pattern matching, see https://www.lua.org/pil/20.2.html\n\nThe default pattern of .+ will trigger whenever the file is non-empty\n\nNOTE: Whitespace characters (spaces, newlines, carriage returns, etc)\nare stripped from the end of the file before matching")

  local contentsmatch = obs.obs_properties_add_bool(props, "contentsmatch", "Make source(s) visible for as long\nas file contents match")
  obs.obs_property_set_modified_callback(contentsmatch, checkboxes_update)

  obs.obs_properties_add_int(props, "duration", "Source visibility\nduration (seconds)", 1, 100000, 1)
  obs.obs_properties_add_int(props, "delay", "Source visibility\ndelay (milliseconds)", 0, 100000, 100)

  -- source choice
  local sources = obs.obs_enum_sources()
  for i=1,NUM_SOURCES do
    local p = obs.obs_properties_add_list(props, "source" .. i, "Source " .. i, obs.OBS_COMBO_TYPE_EDITABLE, obs.OBS_COMBO_FORMAT_STRING)
    if sources ~= nil then
      for _, source in ipairs(sources) do
        local name = obs.obs_source_get_name(source)
        obs.obs_property_list_add_string(p, name, name)
      end
    end
  end
  obs.source_list_release(sources)

  -- scene choice
  local allscenes = obs.obs_properties_add_bool(props, "allscenes", "Affect all scenes")
  obs.obs_property_set_modified_callback(allscenes, checkboxes_update)

  local scenechoice = obs.obs_properties_add_list(props, "scenechoice", "Only affect scene", obs.OBS_COMBO_TYPE_EDITABLE, obs.OBS_COMBO_FORMAT_STRING)
  obs.obs_property_set_long_description(scenechoice, "NOTE: The [current scene] option can behave incorrectly if the\nscene is switched while the trigger is active")
  obs.obs_property_list_add_string(scenechoice, CURRENT_SCENE_OPTION, CURRENT_SCENE_OPTION)

  local sceneSources = obs.obs_frontend_get_scenes()
  for _, sceneSource in ipairs(sceneSources) do
    local name = obs.obs_source_get_name(sceneSource)
    obs.obs_property_list_add_string(scenechoice, name, name)
  end
  obs.source_list_release(sceneSources)

  -- enable/disable stuff based on the settings
  checkboxes_update(props)

  return props
end

-- A function named script_description returns the description shown to
-- the user
function _G.script_description()
  return "Uses a text file as a trigger for making sources visible.\n\nMade by squeek502"
end

-- A function named script_update will be called when settings are changed
function _G.script_update(settings)
  -- reset before the settings are updated
  reset()

  cachedSettings.file = obs.obs_data_get_string(settings, "file")
  cachedSettings.triggerperiod = obs.obs_data_get_int(settings, "triggerperiod")

  cachedSettings.anychange = obs.obs_data_get_bool(settings, "anychange")
  cachedSettings.contents = obs.obs_data_get_string(settings, "contents")
  cachedSettings.contentsmatch = obs.obs_data_get_bool(settings, "contentsmatch")
  cachedSettings.duration = obs.obs_data_get_int(settings, "duration")
  cachedSettings.delay = obs.obs_data_get_int(settings, "delay")

  for i=1,NUM_SOURCES do
    cachedSettings.sources[i] = obs.obs_data_get_string(settings, "source"..i)
  end

  cachedSettings.allscenes = obs.obs_data_get_bool(settings, "allscenes")
  cachedSettings.scenechoice = obs.obs_data_get_string(settings, "scenechoice")

  -- this might be better if its called when the setting actually changes, but
  -- its not a big deal to reset the timer whenever other settings change
  reload()
end

-- A function named script_defaults will be called to set the default settings
function _G.script_defaults(settings)
  obs.obs_data_set_default_int(settings, "duration", 5)
  obs.obs_data_set_default_bool(settings, "anychange", false)
  obs.obs_data_set_default_string(settings, "contents", ".+")
  obs.obs_data_set_default_int(settings, "triggerperiod", 1000)
  obs.obs_data_set_default_int(settings, "delay", 0)
  obs.obs_data_set_default_bool(settings, "allscenes", true)
  obs.obs_data_set_default_string(settings, "scenechoice", CURRENT_SCENE_OPTION)
end

-- A function named script_save will be called when the script is saved
--
-- NOTE: This function is usually used for saving extra data (such as in this
-- case, a hotkey's save data).  Settings set via the properties are saved
-- automatically.
function _G.script_save(settings)

end

local function is_frontend_ready()
  -- this isn't foolproof--just because get_current_scene returns non-nil
  -- it's not necessarily true that everything is fully loaded.
  -- there's probably a better way to check this
  local scene = obs.obs_frontend_get_current_scene()
  local ready = scene ~= nil
  obs.obs_source_release(scene)
  return ready
end

local function try_first_load()
  if is_frontend_ready() then
    obs.timer_remove(try_first_load)
    reload()
  end
end

-- a function named script_load will be called on startup
function _G.script_load(settings)
  -- on OBS startup, these script functions are called before the frontend is loaded
  -- so delay the actual scene visibility stuff until the frontend exists
  if not is_frontend_ready() then
    -- use a full second timer period just to ensure things have a chance to load;
    -- with a smaller interval, we could still be in a partially loaded state
    -- which can lead to weird behavior
    obs.timer_add(try_first_load, 1000)
  end
end
