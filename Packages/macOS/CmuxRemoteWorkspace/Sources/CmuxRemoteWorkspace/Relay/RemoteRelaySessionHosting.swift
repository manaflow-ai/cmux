public import CmuxCore
public import Foundation

/// The live-workspace seam the ``RemoteRelaySessionCoordinator`` reaches back
/// through for the small slice of workspace state its relay-alias and
/// remote-PTY-session-id bookkeeping reads or pushes.
///
/// The coordinator owns the reverse-CLI-relay workspace/surface ID alias maps
/// and the per-panel remote-PTY session-id store. Everything those bodies touch
/// on the workspace that cannot move down a module boundary is reproduced here
/// as one read or push: the workspace ID (the local side of every alias and the
/// `ssh-<workspace>-<panel>` default), the live remote configuration (only its
/// `preserveAfterTerminalExit` flag is consulted), the active-remote-terminal
/// surface set, the pure session-id normalization (which lives on the
/// surface-creation coordinator in a higher package), and the push of the alias
/// maps to the active remote session controller (a `CmuxRemoteSession` type the
/// workspace holds, in a higher package).
///
/// This mirrors the sibling ``RemoteSurfaceHosting`` seam and is `@MainActor`
/// for the same reason: every legacy `Workspace` method lifted into the
/// coordinator was a plain method on the `@MainActor`-isolated `Workspace`
/// class, so all of its reads of live workspace state and its single controller
/// push already ran on the main actor. The coordinator never imports the
/// `Workspace` type; it is witnessed in `Workspace+RemoteRelaySessionHosting.swift`.
@MainActor
public protocol RemoteRelaySessionHosting: AnyObject {
    /// This workspace's own ID: the local side of every relay alias and the
    /// workspace component of the default `ssh-<workspace>-<panel>` session id.
    var hostWorkspaceID: UUID { get }

    /// The live remote configuration, or `nil` when the workspace is local.
    /// Only `preserveAfterTerminalExit` is consulted by the coordinator.
    var hostRemoteConfiguration: WorkspaceRemoteConfiguration? { get }

    /// The set of surface ids currently tracked as active remote terminals.
    var hostActiveRemoteTerminalSurfaceIds: Set<UUID> { get }

    /// Normalizes a remote-PTY session id (trim, treat blank as `nil`), the
    /// pure helper owned by the surface-creation coordinator. Routed through the
    /// host so the single normalization source of truth is preserved.
    func hostNormalizedRemotePTYSessionID(_ value: String?) -> String?

    /// Pushes the current relay alias maps to the active remote session
    /// controller (a no-op when no controller is established). Faithful forward
    /// to `remoteSessionController?.updateRemoteRelayIDAliases(...)`.
    func hostUpdateRemoteRelayIDAliases(
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID]
    )
}
