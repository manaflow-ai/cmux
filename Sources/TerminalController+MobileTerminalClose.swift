import Foundation

extension TerminalController {
    /// Closes one explicitly addressed mobile terminal without changing the
    /// Mac's selected workspace, pane, or surface.
    func v2MobileTerminalClose(params: [String: Any]) -> V2CallResult {
        guard v2HasNonNullParam(params, "workspace_id"),
              let workspaceID = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }

        let terminalID: UUID
        switch mobileTerminalAliasUUID(params: params) {
        case let .value(value):
            terminalID = value
        case .missing, .invalid:
            return .err(code: "invalid_params", message: "Missing or invalid terminal_id", data: nil)
        case .conflict:
            return .err(code: "invalid_params", message: "Conflicting terminal identifiers", data: nil)
        }

        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "Workspace context is unavailable", data: nil)
        }
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else {
            return .err(code: "not_found", message: "Workspace not found", data: [
                "workspace_id": workspaceID.uuidString,
            ])
        }
        guard workspace.terminalPanel(for: terminalID) != nil else {
            return .err(code: "not_found", message: "Terminal not found", data: [
                "workspace_id": workspaceID.uuidString,
                "surface_id": terminalID.uuidString,
            ])
        }

        let terminalCount = workspace.panels.values.reduce(into: 0) { count, panel in
            if panel is TerminalPanel { count += 1 }
        }
        guard terminalCount > 1 else {
            return .err(code: "last_terminal", message: "The workspace's last terminal cannot be closed", data: [
                "workspace_id": workspaceID.uuidString,
                "surface_id": terminalID.uuidString,
            ])
        }

        // Use the shared non-interactive close path: it records close history,
        // preserves remote-tmux routing, and enters bonsplit's normal close
        // delegate just like the Mac tab UI, without presenting a modal prompt.
        guard closeSurfaceRecordingHistory(in: workspace, surfaceId: terminalID, force: true) else {
            return .err(code: "close_failed", message: "Failed to close terminal", data: [
                "workspace_id": workspaceID.uuidString,
                "surface_id": terminalID.uuidString,
            ])
        }
        AppDelegate.shared?.notificationStore?.clearNotifications(
            forTabId: workspaceID,
            surfaceId: terminalID
        )
        return .ok([
            "closed": true,
            "workspace_id": workspaceID.uuidString,
            "surface_id": terminalID.uuidString,
        ])
    }
}
