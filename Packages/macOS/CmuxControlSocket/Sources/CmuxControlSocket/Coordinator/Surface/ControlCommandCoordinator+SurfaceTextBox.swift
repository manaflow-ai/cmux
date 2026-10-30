internal import Foundation

/// `surface.textbox.toggle` / `.show` / `.hide` / `.state`: the scriptable form
/// of the "Toggle TextBox Input" command palette entry, aimed at any terminal
/// surface instead of only the focused one.
extension ControlCommandCoordinator {
    /// Runs one `surface.textbox.*` request.
    ///
    /// `focus: true` (toggle and show only) asks the app to put keyboard focus in
    /// the TextBox it shows; the app grants it only under the socket focus
    /// policy. Without it the TextBox appears and the user's focus stays put.
    ///
    /// - Parameters:
    ///   - action: The requested action.
    ///   - params: The request params (routing selectors, `surface_id`, `focus`).
    /// - Returns: The command result.
    func surfaceTextBox(_ action: ControlSurfaceTextBoxAction, _ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard context?.controlSurfaceRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let focusRequested = action == .toggle || action == .show ? (bool(params, "focus") ?? false) : false
        let resolution = context?.controlSurfaceTextBox(
            action: action,
            routing: routing,
            surfaceID: uuid(params, "surface_id"),
            hasSurfaceIDParam: hasNonNull(params, "surface_id"),
            focusRequested: focusRequested
        ) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .dockUnavailable(let message):
            return .err(code: "unavailable", message: message, data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .surfaceNotFoundForID:
            return .err(code: "not_found", message: "Surface not found for the given surface_id", data: nil)
        case .noFocusedSurface:
            return .err(code: "not_found", message: "No focused surface", data: nil)
        case .surfaceNotTerminal(let id):
            return .err(
                code: "invalid_params",
                message: "Surface is not a terminal",
                data: .object(["surface_id": .string(id.uuidString)])
            )
        case .applied(let windowID, let workspaceID, let surfaceID, let visible, let changed):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "visible": .bool(visible),
                "changed": .bool(changed),
            ]))
        }
    }
}
