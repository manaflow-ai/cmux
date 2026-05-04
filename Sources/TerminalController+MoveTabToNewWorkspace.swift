import Foundation
import Bonsplit

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
        guard v2ResolveTabManager(params: params) != nil else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        guard let directionStr = v2String(params, "direction"),
              let direction = parseSplitDirection(directionStr) else {
            return .err(code: "invalid_params", message: "Missing or invalid direction (left|right|up|down)", data: nil)
        }

        let orientation: SplitOrientation = direction.isHorizontal ? .horizontal : .vertical
        let insertFirst = (direction == .left || direction == .up)
        let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? false)

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to move surface", data: nil)
        v2MainSync {
            guard let app = AppDelegate.shared else {
                result = .err(code: "unavailable", message: "AppDelegate not available", data: nil)
                return
            }
            guard let located = app.locateSurface(surfaceId: surfaceId),
                  let ws = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }) else {
                result = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
                return
            }
            if let requestedWorkspaceId = v2UUID(params, "workspace_id"), requestedWorkspaceId != ws.id {
                result = .err(code: "not_found", message: "Surface not found in workspace", data: [
                    "surface_id": surfaceId.uuidString,
                    "workspace_id": requestedWorkspaceId.uuidString
                ])
                return
            }
            guard let bonsplitTabId = ws.surfaceIdFromPanelId(surfaceId) else {
                result = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
                return
            }
            guard let sourcePane = ws.paneId(forPanelId: surfaceId) else {
                result = .err(code: "not_found", message: "Source pane not found", data: ["surface_id": surfaceId.uuidString])
                return
            }
            guard ws.bonsplitController.tabs(inPane: sourcePane).count > 1 else {
                result = .err(code: "invalid_state", message: "splitting off would leave the source pane empty", data: [
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
                result = .err(code: "internal_error", message: "Failed to split pane", data: nil)
                return
            }
            if focus {
                _ = app.focusMainWindow(windowId: located.windowId)
                setActiveTabManager(located.tabManager)
                if located.tabManager.selectedTabId != ws.id {
                    located.tabManager.selectWorkspace(ws)
                }
                ws.focusPanel(surfaceId)
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
