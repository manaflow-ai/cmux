import Foundation
import Bonsplit

private enum SurfaceSplitOffMessage {
    static let missingSurfaceId = String(localized: "socket.surfaceSplitOff.error.missingSurfaceId", defaultValue: "Missing or invalid surface_id")
    static let invalidWorkspaceId = String(localized: "socket.surfaceSplitOff.error.invalidWorkspaceId", defaultValue: "Missing or invalid workspace_id")
    static let invalidWindowId = String(localized: "socket.surfaceSplitOff.error.invalidWindowId", defaultValue: "Missing or invalid window_id")
    static let invalidDirection = String(localized: "socket.surfaceSplitOff.error.invalidDirection", defaultValue: "Missing or invalid direction (left|right|up|down)")
    static let appDelegateUnavailable = String(localized: "socket.surfaceSplitOff.error.appDelegateUnavailable", defaultValue: "AppDelegate not available")
    static let surfaceNotFound = String(localized: "socket.surfaceSplitOff.error.surfaceNotFound", defaultValue: "Surface not found")
    static let surfaceNotFoundInWorkspace = String(localized: "socket.surfaceSplitOff.error.surfaceNotFoundInWorkspace", defaultValue: "Surface not found in workspace")
    static let surfaceNotFoundInWindow = String(localized: "socket.surfaceSplitOff.error.surfaceNotFoundInWindow", defaultValue: "Surface not found in window")
    static let sourcePaneNotFound = String(localized: "socket.surfaceSplitOff.error.sourcePaneNotFound", defaultValue: "Source pane not found")
    static let wouldEmptySourcePane = String(localized: "socket.surfaceSplitOff.error.wouldEmptySourcePane", defaultValue: "splitting off would leave the source pane empty")
    static let splitPaneFailed = String(localized: "socket.surfaceSplitOff.error.splitPaneFailed", defaultValue: "Failed to split pane")
    static let moveSurfaceFailed = String(localized: "socket.surfaceSplitOff.error.moveSurfaceFailed", defaultValue: "Failed to move surface")
}

extension TerminalController {
    func v2MoveTabToNewWorkspaceActionResult(
        action: String,
        params: [String: Any],
        tabManager: TabManager,
        workspace: Workspace,
        surfaceId: UUID
    ) -> V2CallResult {
        guard workspace.panels.count > 1 else {
            return .err(
                code: "invalid_state",
                message: "Tab cannot be moved to a new workspace because it is the only tab in its workspace",
                data: nil
            )
        }
        guard let app = AppDelegate.shared else {
            return .err(code: "unavailable", message: "AppDelegate not available", data: nil)
        }

        let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? false)
        guard let result = app.moveSurfaceToNewWorkspace(
            panelId: surfaceId,
            destinationManager: tabManager,
            title: v2String(params, "title"),
            focus: focus,
            focusWindow: false
        ) else {
            return .err(code: "internal_error", message: "Failed to move tab to new workspace", data: nil)
        }

        return .ok(v2MoveTabToNewWorkspacePayload(action: action, result: result))
    }

    private func v2MoveTabToNewWorkspacePayload(
        action: String,
        result: SurfaceNewWorkspaceMoveResult
    ) -> [String: Any] {
        [
            "action": action,
            "source_window_id": result.sourceWindowId.uuidString,
            "source_window_ref": v2Ref(kind: .window, uuid: result.sourceWindowId),
            "source_workspace_id": result.sourceWorkspaceId.uuidString,
            "source_workspace_ref": v2Ref(kind: .workspace, uuid: result.sourceWorkspaceId),
            "window_id": v2OrNull(result.destinationWindowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: result.destinationWindowId),
            "workspace_id": result.destinationWorkspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: result.destinationWorkspaceId),
            "created_workspace_id": result.destinationWorkspaceId.uuidString,
            "created_workspace_ref": v2Ref(kind: .workspace, uuid: result.destinationWorkspaceId),
            "surface_id": result.surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: result.surfaceId),
            "tab_id": result.surfaceId.uuidString,
            "tab_ref": v2TabRef(uuid: result.surfaceId),
            "pane_id": v2OrNull(result.paneId?.uuidString),
            "pane_ref": v2Ref(kind: .pane, uuid: result.paneId),
        ]
    }
}

extension TerminalController {
    nonisolated static let explicitFocusParamV2Methods: Set<String> = [
        "workspace.create",
        "workspace.move_to_window",
        "surface.split",
        "surface.create",
        "surface.drag_to_split",
        "surface.split_off",
        "surface.move",
        "surface.reorder",
        "surface.action",
        "tab.action",
        "pane.create",
        "pane.swap",
        "pane.break",
        "pane.join",
        "markdown.open",
        "browser.open_split"
    ]

    nonisolated static func explicitFocusParamAllowsFocus(commandKey: String, params: [String: Any]) -> Bool {
        explicitFocusParamV2Methods.contains(commandKey) && explicitFocusParamValue(params)
    }

    private nonisolated static func explicitFocusParamValue(_ params: [String: Any]) -> Bool {
        guard let raw = params["focus"] else { return false }
        if let bool = raw as? Bool { return bool }
        if let number = raw as? NSNumber { return number.boolValue }
        if let string = raw as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            default:
                return false
            }
        }
        return false
    }
}

extension TerminalController {
    func v2SurfaceDragToSplit(params: [String: Any]) -> V2CallResult {
        return v2SurfaceSplitOff(params: params)
    }

    func v2SurfaceSplitOff(params: [String: Any]) -> V2CallResult {
        let requestedWorkspaceId = v2UUID(params, "workspace_id")
        let requestedWindowId = v2UUID(params, "window_id")
        if params.keys.contains("workspace_id"), requestedWorkspaceId == nil {
            return .err(code: "invalid_params", message: SurfaceSplitOffMessage.invalidWorkspaceId, data: nil)
        }
        if params.keys.contains("window_id"), requestedWindowId == nil {
            return .err(code: "invalid_params", message: SurfaceSplitOffMessage.invalidWindowId, data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: SurfaceSplitOffMessage.missingSurfaceId, data: nil)
        }
        guard let directionStr = v2String(params, "direction"),
              let direction = parseSplitDirection(directionStr) else {
            return .err(code: "invalid_params", message: SurfaceSplitOffMessage.invalidDirection, data: nil)
        }

        let orientation: SplitOrientation = direction.isHorizontal ? .horizontal : .vertical
        let insertFirst = (direction == .left || direction == .up)
        let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? false)

        var result: V2CallResult = .err(code: "internal_error", message: SurfaceSplitOffMessage.moveSurfaceFailed, data: nil)
        v2MainSync {
            guard let app = AppDelegate.shared else {
                result = .err(code: "unavailable", message: SurfaceSplitOffMessage.appDelegateUnavailable, data: nil)
                return
            }
            guard let located = app.locateSurface(surfaceId: surfaceId),
                  let ws = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }) else {
                result = .err(code: "not_found", message: SurfaceSplitOffMessage.surfaceNotFound, data: ["surface_id": surfaceId.uuidString])
                return
            }
            if let requestedWindowId, requestedWindowId != located.windowId {
                result = .err(code: "not_found", message: SurfaceSplitOffMessage.surfaceNotFoundInWindow, data: [
                    "surface_id": surfaceId.uuidString,
                    "window_id": requestedWindowId.uuidString
                ])
                return
            }
            if let requestedWorkspaceId, requestedWorkspaceId != ws.id {
                result = .err(code: "not_found", message: SurfaceSplitOffMessage.surfaceNotFoundInWorkspace, data: [
                    "surface_id": surfaceId.uuidString,
                    "workspace_id": requestedWorkspaceId.uuidString
                ])
                return
            }
            guard let bonsplitTabId = ws.surfaceIdFromPanelId(surfaceId) else {
                result = .err(code: "not_found", message: SurfaceSplitOffMessage.surfaceNotFound, data: ["surface_id": surfaceId.uuidString])
                return
            }
            guard let sourcePane = ws.paneId(forPanelId: surfaceId) else {
                result = .err(code: "not_found", message: SurfaceSplitOffMessage.sourcePaneNotFound, data: ["surface_id": surfaceId.uuidString])
                return
            }
            guard ws.bonsplitController.tabs(inPane: sourcePane).count > 1 else {
                result = .err(code: "invalid_state", message: SurfaceSplitOffMessage.wouldEmptySourcePane, data: [
                    "surface_id": surfaceId.uuidString,
                    "pane_id": sourcePane.id.uuidString
                ])
                return
            }
            let previousFocusedPanelId = ws.focusedPanelId
            guard let newPaneId = ws.bonsplitController.splitPane(
                orientation: orientation,
                movingTab: bonsplitTabId,
                insertFirst: insertFirst
            ) else {
                result = .err(code: "internal_error", message: SurfaceSplitOffMessage.splitPaneFailed, data: nil)
                return
            }
            if focus {
                _ = app.focusMainWindow(windowId: located.windowId)
                setActiveTabManager(located.tabManager)
                located.tabManager.focusTab(ws.id, surfaceId: surfaceId, suppressFlash: true)
            } else if let previousFocusedPanelId, ws.panels[previousFocusedPanelId] != nil {
                ws.focusPanel(previousFocusedPanelId)
            }
            let windowId = located.windowId
            result = .ok([
                "window_id": windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "pane_id": newPaneId.id.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: newPaneId.id)
            ])
        }
        return result
    }
}
