internal import Foundation

/// `surface.agent_chat.open` — open (or focus) the agent chat pane for a
/// surface through the shared `AgentChatPresenter` path. Split from
/// `+Surface2.swift` to stay inside the per-file line budget.
extension ControlCommandCoordinator {
    /// `surface.agent_chat.open` — resolve the target surface and ask the app
    /// to run the shared agent-chat resolve-then-present flow for it.
    func surfaceAgentChatOpen(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard context?.controlSurfaceRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let resolution = context?.controlSurfaceAgentChatOpen(
            routing: routing,
            surfaceID: uuid(params, "surface_id")
        ) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .noFocusedSurface:
            return .err(code: "not_found", message: "No focused surface", data: nil)
        case .surfaceNotFound(let id):
            return .err(
                code: "not_found",
                message: "Surface not found",
                data: .object(["surface_id": .string(id.uuidString)])
            )
        case .requested(let windowID, let workspaceID, let surfaceID):
            return .ok(.object([
                "requested": .bool(true),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
            ]))
        }
    }
}
