import Foundation

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
