public import Foundation

/// The outcome of a remote terminal launching/readiness mutation after the
/// coordinator has validated its workspace and surface identities.
public enum ControlWorkspaceRemoteTerminalSessionConnectedResolution: Sendable, Equatable {
    /// No tracked remote terminal matches the requested workspace and surface.
    case notFound
    /// The terminal handshake was recorded. `workspaceID` is absent when a
    /// window-scoped Dock owns the terminal after its launch workspace closed.
    case resolved(windowID: UUID?, workspaceID: UUID?, remoteStatus: JSONValue)
}
