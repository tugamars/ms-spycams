local QBCore  = exports['qb-core']:GetCoreObject()
local glm = require("glm")

-- Cache
local vec3 = vec3
local quat = quat
local glm_abs = glm.abs
local glm_deg = glm.deg
local glm_sign = glm.sign
local glm_approx = glm.approx
local glm_up = glm.up()
local glm_right = glm.right()
local glm_forward = glm.forward()
local GetEntityRotation = GetEntityRotation
local SetEntityRotation = SetEntityRotation
local SetEntityCoordsNoOffset = SetEntityCoordsNoOffset
local IsDisabledControlPressed = IsDisabledControlPressed
local IsPauseMenuActive = IsPauseMenuActive
local currentObject

local ActiveCams = {}
local Spycam = {}
local Camera = {}
local Streaming = {}
local Scaleform = {}
local Raycast = {}

function Spycam.Add(entity, coords, rotation, onFloor)
    QBCore.Functions.TriggerCallback('spycams:server:canPlace', function(canPlace)
        if canPlace then
            local ped = PlayerPedId()
            local pcoords = GetEntityCoords(ped)
        
            local animDict = 'weapons@projectile@sticky_bomb'
            local animName = onFloor and 'plant_floor' or 'plant_vertical'
        
            SetEntityCoordsNoOffset(entity, coords.x, coords.y, coords.z)
            SetEntityRotation(entity, rotation.x, rotation.y, rotation.z, 4)
            FreezeEntityPosition(entity, true)
            SetEntityCollision(entity, true, true)
            SetEntityAlpha(entity, 0)

            if Config.DrawOutline then
                SetEntityDrawOutline(entity, false)
            end
        
            Streaming.RequestAnimDict(animDict)
        
            if #(coords.xy - pcoords.xy) > 1.0 then
                TaskGoStraightToCoord(ped, coords, 1.0, 2000, GetEntityHeading(entity), 0.01)
                repeat Wait(0) until IsEntityAtCoord(ped, coords.x, coords.y, coords.z, 1.0, 1.0, 1.0, 0, 1, 0)
                ClearPedTasks(ped)
                Wait(500)
            end
        
            TaskTurnPedToFaceEntity(ped, entity, 500)
            TaskPlayAnim(ped, animDict, animName, 8.0, 8.0, -1, 0, 0, false, false, false)
            Wait(math.floor(GetAnimDuration(animDict, animName)*1000))
            ResetEntityAlpha(entity)
            ClearPedTasks(ped)

            if Config.TargetLib == 'ox' then
                exports.ox_target:addLocalEntity({ entity }, {
                    {
                        name = 'spycams:retrieve',
                        event = "spycams:client:interact",
                        icon = Config.TargetIcon,
                        label = Lang:t('target.label'),  
                        distance = Config.TargetDistance      
                    }        
                })
            elseif Config.TargetLib == 'qb' then
                exports['qb-target']:AddTargetEntity(entity, {
                    options = {
                        {
                            type = "client",
                            event = "spycams:client:interact",
                            icon = Config.TargetIcon,
                            label = Lang:t('target.label')
                        },
                    },
                    distance = Config.TargetDistance
                })
            end

            local rotation = GetEntityRotation(entity)
            local coords = GetOffsetFromEntityInWorldCoords(entity, 0.0, 0.0, 0.1)
            local rot = { x = rotation.x + 90.0, y = rotation.y + 180.0, z = rotation.z }
            local netId = NetworkGetNetworkIdFromEntity(entity)
            
            ActiveCams[#ActiveCams + 1] = {
                entity = entity,
                coords = coords,
                viewing = false,
                mode = 'normal',
                startRotation = vec3(rot.x, rot.y, rot.z),
                currentRotation = { x = rot.x, y = rot.y, z = rot.z },
                currentZoom = Config.DefaultFOV                
            }

            TriggerServerEvent('spycams:server:placed')
        end
    end)
end

function Spycam.Remove(entity)
    for i = #ActiveCams, 1, -1 do
        local cam = ActiveCams[i]

        if cam.entity == entity then
            if Config.TargetLib == 'ox' then
                exports.ox_target:removeLocalEntity({ cam.entity })
            elseif Config.TargetLib == 'qb' then
                exports['qb-target']:RemoveTargetEntity(cam.entity)
            end
            SetEntityAsMissionEntity(cam.entity, true, true)
            DeleteEntity(cam.entity)
            table.remove(ActiveCams, i)
            
            break
        end
    end

    if #ActiveCams > 0 then
        Spycam.activeIndex = 1
    end
end

function Spycam.Retrieve(entity)
    Spycam.Remove(entity)
    TriggerServerEvent('spycams:server:removed', false)
end

function Spycam.StartPlacement()
    if placing then return end
    if Spycam.entity then return end

    CreateThread(function()
        local modelHash = joaat('prop_spycam')
        local valid = false
        local player = PlayerPedId()
        local keys = Config.Controls.place
        local buttons = Scaleform.SetInstructionalButtons(keys)

        Streaming.RequestModel(modelHash)
        currentObject = CreateObject(modelHash, GetEntityCoords(player), true, true, true)
        SetEntityCollision(currentObject, false, false)

        if Config.DrawOutline then
            SetEntityDrawOutline(currentObject, true)
            SetEntityDrawOutlineShader(1)
        end            

        placing = true

        while placing do
            DisableControlAction(0, 10, true)
            DisableControlAction(0, 11, true)
            DisableControlAction(0, 14, true)
            DisableControlAction(0, 15, true)
            DisableControlAction(0, 24, true)
            DisableControlAction(0, 25, true)
            DisableControlAction(0, 174, true)
            DisableControlAction(0, 175, true)

            if not IsPauseMenuActive() then
                local pcoords = GetEntityCoords(player)
                local r, hit, coords, norm, material, entity = Raycast.RaycastFromCamera(player)

                DrawScaleformMovieFullscreen(buttons, 255, 255, 255, 255, 0)

                if hit ~= 0 then
                    norm = glm.normalize(norm)
                    local _, rotation = Raycast.SurfaceNormalToRotation(norm)
                    coords = coords + norm * 0.01
                    
                    local isHorizontal = rotation.y > -20.00 and rotation.y < 20.00
                    local invalidSurface = Config.MaterialsBlacklist[material] or 
                    IsEntityAVehicle(entity) or 
                    (IsEntityAnObject(entity) and not Config.PlaceOnObjects) or 
                    (isHorizontal and not Config.PlaceOnFloor)

                    -- Limit height
                    if coords.z > pcoords.z + Config.MaxPlaceHeight then
                        coords = vec3(coords.x, coords.y, pcoords.z + Config.MaxPlaceHeight)
                    end

                    if Config.DrawOutline then
                        local color = { r = 255, g = invalidSurface and 0 or 255, b = invalidSurface and 0 or 255, a = 255 }
                        SetEntityDrawOutlineColor(color.r, color.g, color.b, color.a)
                    end

                    SetEntityCoordsNoOffset(currentObject, coords.x, coords.y, coords.z)
                    SetEntityRotation(currentObject, rotation.x, rotation.y, rotation.z, 4)

                    if IsDisabledControlJustPressed(0, keys.place.button) then
                        if invalidSurface then
                            QBCore.Functions.Notify(Lang:t('errors.invalid'), 'error', 7500)
                        else
                            placing = false
                            Spycam.Add(currentObject, coords, rotation, isHorizontal)
                        end
                    end                  
                end

                if IsDisabledControlJustPressed(0, keys.cancel.button) then
                    SetScaleformMovieAsNoLongerNeeded(Scaleform.Buttons)
                    SetEntityAsMissionEntity(currentObject, true, true)
                    DeleteEntity(currentObject)
                    placing = false
                end   
            end

            Wait(0)
        end
    end)
end

function Spycam.Connect()
    if #ActiveCams == 0 then return end

    local player = PlayerPedId()
    local pcoords = GetEntityCoords(player)
    local animDict = 'amb@code_human_in_bus_passenger_idles@female@tablet@idle_a'
    local animName = 'idle_a'
    local tabletModel = joaat('prop_cs_tablet')
    
    Streaming.RequestModel(tabletModel)
    Streaming.RequestAnimDict(animDict)

    Spycam.Tablet = CreateObject(tabletModel, pcoords, true, true, false)
    AttachEntityToEntity(Spycam.Tablet, player, GetPedBoneIndex(player, 28422), -0.05, 0.0, 0.0, 0.0, 0.0, 0.0, true, true, false, true, 1, true)
    SetModelAsNoLongerNeeded(tabletModel)
    TaskPlayAnim(player, animDict, animName, 2.0, 2.0, -1, 51, 0, false, false, false)
    RemoveAnimDict(animDict)
    SetEntityAsMissionEntity(Spycam.Tablet, true, true)

    Camera.Create()
end

function Spycam.Disconnect()
    Camera.Destroy()

    if Spycam.Tablet then
        DetachEntity(Spycam.Tablet)
        DeleteEntity(Spycam.Tablet)
        Spycam.Tablet = nil
    end

    ClearPedTasks(PlayerPedId())
end

function Spycam.SelfDestruct(currentIndex, currentCam)
    if not currentCam.inRange then
        return QBCore.Functions.Notify(Lang:t('errors.range'), 'error')
    end

    QBCore.Functions.Notify(Lang:t('general.destroy', { time = Config.SelfDestructTime }), 'error')

    SetTimeout(Config.SelfDestructTime * 1000, function()
        currentCam.destroyed = true

        QBCore.Functions.Notify(Lang:t('general.destroyed'), 'success')
        TriggerServerEvent('spycams:server:destroyed', currentCam.coords)
        TriggerServerEvent('spycams:server:removed', true)

        if currentIndex == Spycam.activeIndex then
            SetTimecycleModifier("CAMERA_secuirity_FUZZ")
            SetTimecycleModifierStrength(1.0)
            SetExtraTimecycleModifier("NG_blackout")
            SetExtraTimecycleModifierStrength(1.0)
        end 

        Wait(3000)

        Spycam.Remove(currentCam.entity)

        if #ActiveCams == 0 then
            Spycam.Disconnect()
            Spycam.activeIndex = 1
        else
            Spycam.activeIndex = 1
            Camera.Activate()
        end
    end)
end

function Camera.Activate()
    if #ActiveCams == 0 then return end
    
    if not Spycam.activeIndex then
        Spycam.activeIndex = 1
    end

    local currentCam = ActiveCams[Spycam.activeIndex]
    
    Config.OnEnterCam()

    if not Spycam.Cam then
        Spycam.Cam = CreateCamWithParams("DEFAULT_SCRIPTED_CAMERA", currentCam.coords, currentCam.startRotation, currentCam.currentZoom)
    end

    ClearFocus()
    SetCamActive(Spycam.Cam, true)
    RenderScriptCams(true, false, 0, true, false)
    SetCamAffectsAiming(Spycam.Cam, false)

    -- Set camera position
    SetCamCoord(Spycam.Cam, currentCam.coords)

    -- Set camera rotation
    -- We can do this with the last two params of CreateCamWithParams, but they're undocumented so we'll do it here for now
    SetCamRot(Spycam.Cam, currentCam.currentRotation.x, currentCam.currentRotation.y, currentCam.currentRotation.z, 2)

    -- Load the area around the cam otherwise we'll see low quality LODs
    SetFocusPosAndVel(currentCam.coords.x, currentCam.coords.y, currentCam.coords.z, 20.0, 20.0, 20.0)

    if currentCam.mode == 'normal' then
        SetNightvision(false)
        SetSeethrough(false)
    elseif currentCam.mode == 'night' then
        SetNightvision(true)
        SetSeethrough(false)
    elseif currentCam.mode == 'thermal' then
        SetNightvision(false)
        SetSeethrough(true)
    end

    local player = PlayerPedId()
    local pcoords = GetEntityCoords(player)
    local dist = #(currentCam.coords - pcoords)

    ClearTimecycleModifier()
    ClearExtraTimecycleModifier()

    if dist > Config.SignalDistance or currentCam.destroyed then
        currentCam.inRange = false
        SetTimecycleModifier("CAMERA_secuirity_FUZZ")
        SetTimecycleModifierStrength(1.0)
        SetExtraTimecycleModifier("NG_blackout")
        SetExtraTimecycleModifierStrength(1.0)
    else
        currentCam.inRange = true
        SetTimecycleModifier(Config.ScreenEffect)
        SetTimecycleModifierStrength(Config.EffectStrength)          
    end
end

function Camera.Create()
    local keys = Config.Controls.camera
    local buttons = Scaleform.SetInstructionalButtons(keys)
    local player = PlayerPedId()

    CreateThread(function()
        Camera.Activate()

        while Spycam.Cam do
            local currentCam = ActiveCams[Spycam.activeIndex]

            if currentCam then
                -- Stop player moving
                DisableAllControlActions(0)

                -- Display instructional buttons
                DrawScaleformMovieFullscreen(buttons, 255, 255, 255, 255, 0)

                if not currentCam.inRange then
                    DrawMessage(0.5, 0.5, 0.8, 255, 255, 255, 255, Lang:t('general.nosignal'))
                end

                if IsDisabledControlJustPressed(0, 174) then
                    if Spycam.activeIndex > 1 then
                        Spycam.activeIndex = Spycam.activeIndex - 1
                    else
                        Spycam.activeIndex = #ActiveCams
                    end

                    Camera.Activate()
                elseif IsDisabledControlJustPressed(0, 175) then
                    if Spycam.activeIndex < #ActiveCams then
                        Spycam.activeIndex = Spycam.activeIndex + 1
                    else
                        Spycam.activeIndex = 1
                    end

                    Camera.Activate()
                end 

                -- Exit the camera view
                if IsDisabledControlJustPressed(0, keys.disconnect.button) then
                    Spycam.Disconnect()
                end

                -- Self-destruct
                if IsDisabledControlJustPressed(0, keys.destroy.button) then
                    Spycam.SelfDestruct(Spycam.activeIndex, currentCam)
                end

                if currentCam.inRange then
                    -- Camera movement controls
                    local camMoving = false
                    if IsDisabledControlPressed(0, keys.moveup.button) then
                        camMoving = true
                        currentCam.currentRotation.x = currentCam.currentRotation.x - Config.MoveStep
                    end
                
                    if IsDisabledControlPressed(0, keys.movedown.button) then
                        camMoving = true
                        currentCam.currentRotation.x = currentCam.currentRotation.x + Config.MoveStep
                    end
                
                    if IsDisabledControlPressed(0, keys.moveleft.button) then
                        camMoving = true
                        currentCam.currentRotation.z = currentCam.currentRotation.z + Config.MoveStep
                    end
                
                    if IsDisabledControlPressed(0, keys.moveright.button) then
                        camMoving = true
                        currentCam.currentRotation.z = currentCam.currentRotation.z - Config.MoveStep
                    end           

                    -- Camera zoom controls
                    if IsDisabledControlJustPressed(0, keys.zoomin.button) then
                        currentCam.currentZoom = currentCam.currentZoom - Config.ZoomStep
                        currentCam.currentZoom = math.max(currentCam.currentZoom, Config.MinFOV)
                        SetCamFov(Spycam.Cam, currentCam.currentZoom)
                    elseif IsDisabledControlJustPressed(0, keys.zoomout.button) then
                        currentCam.currentZoom = currentCam.currentZoom + Config.ZoomStep
                        currentCam.currentZoom = math.min(currentCam.currentZoom, Config.MaxFOV)
                        SetCamFov(Spycam.Cam, currentCam.currentZoom)
                    end

                    -- Camera vision mode controls
                    if IsDisabledControlJustPressed(0, keys.mode.button) then
                        if currentCam.mode == 'normal' then
                            currentCam.mode = 'night'
                            SetNightvision(true)
                        elseif currentCam.mode == 'night' then
                            currentCam.mode = 'thermal'
                            SetNightvision(false)
                            SetSeethrough(true)
                        elseif currentCam.mode == 'thermal' then
                            currentCam.mode = 'normal'
                            SetSeethrough(false)
                        end
                    end
                
                    -- Set the camera rotation
                    if camMoving then
                        if currentCam.currentRotation.x >= currentCam.startRotation.x + Config.MaxRotationX then
                            currentCam.currentRotation.x = currentCam.startRotation.x + Config.MaxRotationX
                        end
                    
                        if currentCam.currentRotation.x <= currentCam.startRotation.x - Config.MaxRotationX then
                            currentCam.currentRotation.x = currentCam.startRotation.x - Config.MaxRotationX
                        end     
                    
                        if currentCam.currentRotation.z >= currentCam.startRotation.z + Config.MaxRotationZ then
                            currentCam.currentRotation.z = currentCam.startRotation.z + Config.MaxRotationZ
                        end
                    
                        if currentCam.currentRotation.z <= currentCam.startRotation.z - Config.MaxRotationZ then
                            currentCam.currentRotation.z = currentCam.startRotation.z - Config.MaxRotationZ
                        end

                        SetCamRot(Spycam.Cam, currentCam.currentRotation.x, currentCam.currentRotation.y, currentCam.currentRotation.z, 2)
                    end
                end
            end

            Wait(0)
        end
    end)
end

function Camera.Destroy()
    Config.OnExitCam()
    ClearFocus()
    RenderScriptCams(false, false, 0, true, false)

    if Spycam.Cam then
        DestroyCam(Spycam.Cam, true)
        Spycam.Cam = nil
    end
    SetSeethrough(false)
    SetNightvision(false)
    ClearTimecycleModifier()
    ClearExtraTimecycleModifier()
end

--- Source: https://github.com/citizenfx/lua/blob/luaglm-dev/cfx/libs/scripts/examples/scripting_gta.lua
function Raycast.SurfaceNormalToRotation(normal)
    local quat_eps = 1E-2
    local surfaceFlip = quat(180.0, glm_forward)
    local q = nil
    if glm_approx(glm_abs(normal.z), 1.0, quat_eps) then
        local camRot = GetFinalRenderedCamRot(2)
        local counterRotation = (glm_sign(normal.z) * -camRot.z) - 90.0

        q = glm.quatlookRotation(normal, glm_right)
        q = q * quat(counterRotation, glm_up)
    elseif glm_approx(normal.y, 1.0, quat_eps) then
        q = glm.quatlookRotation(normal, -glm_up)
        surfaceFlip = quat(180.0, glm_right)
    else
        q = glm.quatlookRotation(normal, glm_up)
    end

    local euler = vec3(glm.extractEulerAngleYXZ(q * surfaceFlip))
    return q,glm_deg(vec3(euler[2],euler[1],euler[3]))
end

function Raycast.RaycastFromCamera(player)
    local pcoords = GetEntityCoords(player)
    local camRotation = GetGameplayCamRot(0)
    local camCoords = GetGameplayCamCoord()
    local camDirection = Raycast.RotationToDirection(camRotation)

    local dest = vec3(
        camCoords.x + (camDirection.x * Config.MaxPlaceDistance),
        camCoords.y + (camDirection.y * Config.MaxPlaceDistance),
        camCoords.z + (camDirection.z * Config.MaxPlaceDistance)
    )

    local ray = StartExpensiveSynchronousShapeTestLosProbe(camCoords, dest, -1, player, 7)
    return GetShapeTestResultIncludingMaterial(ray)
end

function Raycast.RotationToDirection(rotation)
    local rad = math.pi / 180
    local adjustedRotation = { 
        x = rad * rotation.x, 
        y = rad * rotation.y, 
        z = rad * rotation.z 
    }

    return vec3(
        -math.sin(adjustedRotation.z) * math.abs(math.cos(adjustedRotation.x)), 
        math.cos(adjustedRotation.z) * math.abs(math.cos(adjustedRotation.x)), 
        math.sin(adjustedRotation.x)
    )
end


-- STREAMING

function Streaming.RequestAnimDict(dict)
    if HasAnimDictLoaded(dict) then return end
    RequestAnimDict(dict)
    while not HasAnimDictLoaded(dict) do
        Wait(1)
    end
end

function Streaming.RequestModel(model)
    if HasModelLoaded(model) then return end
    RequestModel(model)
    while not HasModelLoaded(model) do
        Wait(1)
    end
end

function Streaming.RequestPtfx(ptfx)
    if HasNamedPtfxAssetLoaded(ptfx) then return end
    RequestNamedPtfxAsset(ptfx)
    while not HasNamedPtfxAssetLoaded(ptfx) do
        Wait(1)
    end
end


-- SCALEFORM

function Scaleform.SetInstructionalButtons(data)
    if Scaleform.Buttons then
        SetScaleformMovieAsNoLongerNeeded(Scaleform.Buttons)
    end

    Scaleform.Buttons = RequestScaleformMovie("instructional_buttons")

    while not HasScaleformMovieLoaded(Scaleform.Buttons) do
        Wait(0)
    end

    PushScaleformMovieFunction(Scaleform.Buttons, "CLEAR_ALL")
    PopScaleformMovieFunctionVoid()
    
    PushScaleformMovieFunction(Scaleform.Buttons, "SET_CLEAR_SPACE")
    PushScaleformMovieFunctionParameterInt(200)
    PopScaleformMovieFunctionVoid()

    local index = 0

    for id, btn in orderedPairs(data) do
        Scaleform.AddInstuctionalButton(btn.label, btn.button, index)
        index = index + 1
    end

    PushScaleformMovieFunction(Scaleform.Buttons, "DRAW_INSTRUCTIONAL_BUTTONS")
    PopScaleformMovieFunctionVoid()

    PushScaleformMovieFunction(Scaleform.Buttons, "SET_BACKGROUND_COLOUR")
    PushScaleformMovieFunctionParameterInt(0)
    PushScaleformMovieFunctionParameterInt(0)
    PushScaleformMovieFunctionParameterInt(0)
    PushScaleformMovieFunctionParameterInt(50)
    PopScaleformMovieFunctionVoid()

    return Scaleform.Buttons
end

function Scaleform.AddInstuctionalButton(text, key, index)
    PushScaleformMovieFunction(Scaleform.Buttons, "SET_DATA_SLOT")
    PushScaleformMovieFunctionParameterInt(index)
    ScaleformMovieMethodAddParamPlayerNameString(GetControlInstructionalButton(2, key, true))
    Scaleform.SetButtonMessage(text)
    PopScaleformMovieFunctionVoid()
end

function Scaleform.SetButtonMessage(text)
    BeginTextCommandScaleformString("STRING")
    AddTextComponentScaleform(text)
    EndTextCommandScaleformString()
end


-- EVENT HANDLERS

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    TriggerEvent('chat:addSuggestion', '/spycams:connect', 'Connect to deployed spy cameras', {})
end)

RegisterNetEvent('spycams:client:place', function()
    Spycam.StartPlacement()
end)

RegisterNetEvent('spycams:client:connect', function()
    Spycam.Connect()
end)

RegisterNetEvent('spycams:client:diconnect', function()
    Spycam.Disconnect()
end)

RegisterNetEvent('spycams:client:destroyed', function(coords)
    Streaming.RequestPtfx('scr_xs_props')
    UseParticleFxAssetNextCall('scr_xs_props')
    StartParticleFxNonLoopedAtCoord('scr_xs_ball_explosion', coords, 0.0, 0.0, 0.0, 0.6, false, false, false, false)
end)

AddEventHandler("spycams:client:interact", function(data)
    if data.name == 'spycams:retrieve' then
        Spycam.Retrieve(data.entity)
    elseif data.name == 'spycams:connect' then
        Spycam.Connect()
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    Spycam.Disconnect()
end)


-- COMMANDS

RegisterCommand('spycams:connect', function()
    Spycam.Connect()
end)

RegisterCommand('spycams:disconnect', function()
    Spycam.Disconnect()
end)


-- EXPORTS

exports('Connect', function()
    return Spycam.Connect()
end)

exports('Disconnect', function()
    return Spycam.Disconnect()
end)

