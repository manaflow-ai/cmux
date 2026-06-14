internal import Foundation

/// Workspace tab-color commands owned by ``ControlCommandCoordinator``.
extension ControlCommandCoordinator {
    /// `workspace.set_color` — set a workspace's custom tab color.
    ///
    /// The app target keeps the palette lookup and mutation logic; the
    /// coordinator owns dispatch and response encoding.
    ///
    /// - Parameter params: The decoded request parameters.
    /// - Returns: The command result.
    func workspaceSetColor(_ params: [String: JSONValue]) -> ControlCallResult {
        context?.controlSetWorkspaceColor(params: params)
            ?? .err(code: "unavailable", message: "No workspace window is available.", data: nil)
    }

    /// `workspace.clear_color` — clear a workspace's custom tab color.
    ///
    /// - Parameter params: The decoded request parameters.
    /// - Returns: The command result.
    func workspaceClearColor(_ params: [String: JSONValue]) -> ControlCallResult {
        context?.controlClearWorkspaceColor(params: params)
            ?? .err(code: "unavailable", message: "No workspace window is available.", data: nil)
    }
}
