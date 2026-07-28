public import Foundation

/// The outcome of `workspace.remote.terminal_session_connected`, after the
/// coordinator has validated the workspace, surface, and optional relay port.
public enum ControlWorkspaceRemoteTerminalSessionConnectedResolution: Sendable, Equatable {
    /// No tracked remote terminal matches the requested workspace and surface.
    case notFound
    /// The terminal handshake was recorded for the resolved workspace.
    case resolved(windowID: UUID?, workspaceID: UUID, remoteStatus: JSONValue)
}
