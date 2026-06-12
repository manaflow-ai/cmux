internal import Foundation

/// `surface.agent_chat.open` — open (or focus) the agent chat pane for a
/// surface through the shared `AgentChatPresenter` path. Split from
/// `+Surface2.swift` to stay inside the per-file line budget.
extension ControlCommandCoordinator {
    /// `surface.agent_chat.open` — resolve the target surface and ask the app
    /// to run the shared agent-chat resolve-then-present flow for it.
    func surfaceAgentChatOpen(_ params: [String: JSONValue]) -> ControlCallResult {
        // A present-but-malformed explicit selector must not silently fall
        // back to the current window/workspace/focused surface: this verb is
        // focus-intent and opens UI, so a typo'd target would mutate the
        // wrong place and report success (same rule as the resume verbs).
        // Validated BEFORE the availability guard: a malformed window_id
        // also fails TabManager resolution, which would misreport caller
        // error as `unavailable`.
        for key in ["window_id", "workspace_id", "surface_id", "terminal_id", "tab_id"]
        where hasNonNull(params, key) {
            if uuid(params, key) == nil {
                return .err(code: "invalid_params", message: "Missing or invalid \(key)", data: nil)
            }
        }
        let routing = routingSelectors(params)
        guard context?.controlSurfaceRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let resolution = context?.controlSurfaceAgentChatOpen(
            routing: routing,
            // The alias-resolved surface selector (surface_id / terminal_id /
            // tab_id), exactly what routingSelectors computed — forwarding
            // only surface_id would drop the aliases and fall back to the
            // focused surface for a caller who targeted explicitly.
            surfaceID: routing.surfaceID
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
