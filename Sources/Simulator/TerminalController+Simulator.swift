import Bonsplit
import Foundation

extension TerminalController {
    func v2SimulatorCall(method: String, params: [String: Any]) -> V2CallResult {
        switch method {
        case "simulator.open": return v2SimulatorOpen(params: params)
        case "simulator.list": return v2SimulatorList(params: params)
        case "simulator.boot": return v2SimulatorBoot(params: params)
        case "simulator.shutdown": return v2SimulatorShutdown(params: params)
        default: return .err(code: "invalid_method", message: "Unknown simulator method", data: nil)
        }
    }

    func v2SimulatorList(params: [String: Any]) -> V2CallResult {
        _ = params
        do {
            let devices = try SimulatorService.shared.listDevices()
            let payload = devices.map { device -> [String: Any] in
                [
                    "udid": device.udid,
                    "name": device.name,
                    "state": device.state.rawValue,
                    "runtime": device.runtime,
                    "is_booted": device.isBooted,
                ]
            }
            return .ok(["devices": payload])
        } catch {
            return .err(code: "simulator_unavailable", message: error.localizedDescription, data: nil)
        }
    }

    func v2SimulatorBoot(params: [String: Any]) -> V2CallResult {
        guard let udid = v2String(params, "udid"), !udid.isEmpty else {
            return .err(code: "invalid_params", message: "Missing 'udid'", data: nil)
        }
        if let validationError = v2SimulatorDeviceValidationError(udid: udid) {
            return validationError
        }
        Task.detached(priority: .userInitiated) {
            do {
                try SimulatorService.shared.boot(udid: udid)
#if DEBUG
                cmuxDebugLog("simulator.boot.success udid=\(udid.prefix(8))")
#endif
            } catch {
#if DEBUG
                cmuxDebugLog("simulator.boot.error udid=\(udid.prefix(8)) error=\(error.localizedDescription)")
#endif
            }
        }
        return .ok(["udid": udid, "status": "booting"])
    }

    func v2SimulatorShutdown(params: [String: Any]) -> V2CallResult {
        guard let udid = v2String(params, "udid"), !udid.isEmpty else {
            return .err(code: "invalid_params", message: "Missing 'udid'", data: nil)
        }
        if let validationError = v2SimulatorDeviceValidationError(udid: udid) {
            return validationError
        }
        Task.detached(priority: .userInitiated) {
            do {
                try SimulatorService.shared.shutdown(udid: udid)
#if DEBUG
                cmuxDebugLog("simulator.shutdown.success udid=\(udid.prefix(8))")
#endif
            } catch {
#if DEBUG
                cmuxDebugLog("simulator.shutdown.error udid=\(udid.prefix(8)) error=\(error.localizedDescription)")
#endif
            }
        }
        return .ok(["udid": udid, "status": "shutting_down"])
    }

    func v2SimulatorOpen(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let preferredUDID = v2String(params, "udid")?.trimmingCharacters(in: .whitespaces)
        if let preferredUDID, !preferredUDID.isEmpty,
           let validationError = v2SimulatorDeviceValidationError(udid: preferredUDID) {
            return validationError
        }
        let directionStr = v2String(params, "direction") ?? "right"
        guard let direction = parseSplitDirection(directionStr) else {
            return .err(
                code: "invalid_params",
                message: "Invalid direction '\(directionStr)' (left|right|up|down)",
                data: nil
            )
        }

        var result: V2CallResult = .err(
            code: "internal_error",
            message: "Failed to create simulator panel",
            data: nil
        )
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            v2MaybeFocusWindow(for: tabManager)
            v2MaybeSelectWorkspace(tabManager, workspace: ws)

            let sourceSurfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let sourceSurfaceId else {
                result = .err(code: "not_found", message: "No focused surface to split", data: nil)
                return
            }
            guard ws.panels[sourceSurfaceId] != nil else {
                result = .err(
                    code: "not_found",
                    message: "Source surface not found",
                    data: ["surface_id": sourceSurfaceId.uuidString]
                )
                return
            }

            let sourcePaneUUID = ws.paneId(forPanelId: sourceSurfaceId)?.id
            let orientation: SplitOrientation = direction.isHorizontal ? .horizontal : .vertical
            let insertFirst = (direction == .left || direction == .up)

            let createdPanel = ws.newSimulatorSplit(
                from: sourceSurfaceId,
                orientation: orientation,
                insertFirst: insertFirst,
                preferredUDID: preferredUDID?.isEmpty == false ? preferredUDID : nil,
                focus: v2FocusAllowed()
            )
            guard let simulatorPanelId = createdPanel?.id else {
                result = .err(
                    code: "internal_error",
                    message: "Failed to create simulator panel",
                    data: nil
                )
                return
            }

            let targetPaneUUID = ws.paneId(forPanelId: simulatorPanelId)?.id
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": v2OrNull(targetPaneUUID?.uuidString),
                "pane_ref": v2Ref(kind: .pane, uuid: targetPaneUUID),
                "surface_id": simulatorPanelId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: simulatorPanelId),
                "source_surface_id": sourceSurfaceId.uuidString,
                "source_surface_ref": v2Ref(kind: .surface, uuid: sourceSurfaceId),
                "source_pane_id": v2OrNull(sourcePaneUUID?.uuidString),
                "source_pane_ref": v2Ref(kind: .pane, uuid: sourcePaneUUID),
                "udid": v2OrNull(preferredUDID?.isEmpty == false ? preferredUDID : nil),
            ])
        }
        return result
    }

    private func v2SimulatorDeviceValidationError(udid: String) -> V2CallResult? {
        do {
            guard try SimulatorService.shared.resolveDevice(udid: udid) != nil else {
                return .err(code: "not_found", message: "Simulator not found: \(udid)", data: ["udid": udid])
            }
            return nil
        } catch {
            return .err(code: "simulator_unavailable", message: error.localizedDescription, data: ["udid": udid])
        }
    }
}
