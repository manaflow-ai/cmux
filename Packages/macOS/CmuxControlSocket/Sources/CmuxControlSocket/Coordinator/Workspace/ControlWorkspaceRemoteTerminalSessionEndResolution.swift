public import Foundation

/// The outcome of `workspace.remote.terminal_session_end`, after the
/// coordinator has validated `workspace_id` / `surface_id` / `relay_port`.
public enum ControlWorkspaceRemoteTerminalSessionEndResolution: Sendable, Equatable {
    /// The workspace was not found (legacy `not_found` / "Workspace not found",
    /// data carries workspace + surface + relay_port).
    case notFound
    /// The session end was recorded. Carries the owning window id (may be
    /// absent), the resolved workspace id, and the bridged
    /// `remoteStatusPayload()`.
    case resolved(windowID: UUID?, workspaceID: UUID, remoteStatus: JSONValue)
}
