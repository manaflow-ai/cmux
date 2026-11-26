public import Foundation

/// The outcome of `workspace.remote.terminal_session_end`, after the
/// coordinator has validated `workspace_id` / `surface_id` / `relay_port`.
public enum ControlWorkspaceRemoteTerminalSessionEndResolution: Sendable, Equatable {
    /// The workspace was not found (legacy `not_found` / "Workspace not found",
    /// data carries workspace + surface + relay_port).
    case notFound
    /// The session end was recorded. `workspaceID` is absent when a
    /// window-scoped Dock owns the terminal after its launch workspace closed.
    case resolved(windowID: UUID?, workspaceID: UUID?, remoteStatus: JSONValue)
}
