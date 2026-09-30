internal import Foundation

extension ControlCommandCoordinator {
    /// `workspace.close` — close a workspace by id.
    func workspaceClose(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        // Legacy resolved the TabManager BEFORE param validation, so unresolvable
        // routing wins over a missing/invalid param (`unavailable` first).
        guard context?.controlWorkspaceRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let workspaceID = uuid(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        let resolution = context?.controlCloseWorkspace(
            routing: routing,
            workspaceID: workspaceID
        ) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .protected(let windowID):
            let message = context?.controlWorkspaceStrings().closeProtected ?? ""
            return .err(code: "protected", message: message, data: .object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "pinned": .bool(true),
            ]))
        case .notFound:
            return .err(code: "not_found", message: "Workspace not found", data: .object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
            ]))
        case .closeFailed(let windowID):
            let message = context?.controlWorkspaceStrings().closeFailed ?? ""
            return .err(code: "internal_error", message: message, data: .object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
            ]))
        case .resolved(let windowID):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
            ]))
        }
    }
}
