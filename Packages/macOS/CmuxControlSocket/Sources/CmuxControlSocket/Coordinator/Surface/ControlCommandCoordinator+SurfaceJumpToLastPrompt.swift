internal import Foundation

/// `surface.jump_to_last_prompt` plus the focus-result encoding it shares with
/// `surface.focus`. Split out of `+Surface.swift` (500-line budget).
extension ControlCommandCoordinator {
    /// `surface.jump_to_last_prompt`: focus the surface where the user last
    /// submitted an agent prompt. Answers `{"opened": false}` when there is
    /// none; otherwise the `surface.focus` payload plus `"opened": true`.
    func surfaceJumpToLastPrompt() -> ControlCallResult {
        guard let resolution = context?.controlSurfaceJumpToLastPrompt() else {
            return .ok(.object(["opened": .bool(false)]))
        }
        let result = surfaceFocusResult(resolution, requestedSurfaceID: nil)
        guard case .ok(.object(var payload)) = result else { return result }
        payload["opened"] = .bool(true)
        return .ok(.object(payload))
    }

    /// Encodes a ``ControlSurfaceFocusResolution`` the way `surface.focus`
    /// always has. `requestedSurfaceID` echoes into the Dock error data; it is
    /// nil when the caller did not name a surface.
    func surfaceFocusResult(
        _ resolution: ControlSurfaceFocusResolution,
        requestedSurfaceID: UUID?
    ) -> ControlCallResult {
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .surfaceNotFound(let id):
            return .err(
                code: "not_found",
                message: "Surface not found",
                data: .object(["surface_id": .string(id.uuidString)])
            )
        case .dockUnavailable(let message):
            return .err(
                code: "unavailable",
                message: message,
                data: requestedSurfaceID.map { JSONValue.object(["surface_id": .string($0.uuidString)]) }
            )
        case .focused(let windowID, let workspaceID, let focusedSurfaceID):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "surface_id": .string(focusedSurfaceID.uuidString),
                "surface_ref": ref(.surface, focusedSurfaceID),
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
            ]))
        }
    }
}
