public import Foundation

/// The outcome of `workspace.remote.pty_attach_end`, after the coordinator has
/// validated `workspace_id` / `surface_id` / `session_id`.
///
/// Both outcomes encode as a success envelope: when the workspace is not found
/// the legacy body returns its `workspace_found: false` default `ok` payload,
/// so the coordinator shapes that from `notFound`.
public enum ControlWorkspaceRemotePTYAttachEndResolution: Sendable, Equatable {
    /// The workspace/surface was not located (legacy `workspace_found: false`
    /// default ok payload).
    case notFound
    /// The attach end was recorded. Carries the owning window id (may be
    /// absent), the resolved workspace id (the located owner's workspace, which
    /// may differ from the requested id), the cleared/untracked flags, and the
    /// bridged `remoteStatusPayload()`.
    case resolved(
        windowID: UUID?,
        workspaceID: UUID,
        clearedRemotePTYSession: Bool,
        untrackedRemoteTerminal: Bool,
        remoteStatus: JSONValue
    )
}
