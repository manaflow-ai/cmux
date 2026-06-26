public import CmuxCore
public import Foundation

/// The live-workspace seam the ``RemoteSurfaceCoordinator`` reaches back
/// through for the small slice of per-surface state its orchestration reads or
/// mutates.
///
/// The surface coordinator owns the *command orchestration* (remote PTY bridge
/// list/start/resize/detach, remote port-scan kick/sync/enablement, dropped-file
/// upload, and the child-exit surface-tracking predicates). Everything those
/// bodies touch on the workspace that cannot move down a module boundary is
/// reproduced here as one read or mutation: the active session coordinator, the
/// remote-workspace flag, the per-surface TTY names, the active/ended/pending
/// remote-terminal surface sets, the live remote configuration, and the single
/// session-ended mutation.
///
/// This mirrors the publish-side ``RemoteSessionHosting`` seam, but in the
/// opposite isolation direction: every legacy `Workspace` method lifted into
/// the surface coordinator was a plain method on the `@MainActor`-isolated
/// `Workspace` class, so all of its reads of live workspace state already
/// happened on the main actor. The seam is therefore `@MainActor`, the
/// coordinator that consumes it is `@MainActor`, and the app target conforms
/// `Workspace` (itself `@MainActor`) directly with no bridging adapter. The
/// coordinator never imports the `Workspace` type; it is witnessed in
/// `Workspace+RemoteSurfaceHosting.swift`.
@MainActor
public protocol RemoteSurfaceHosting: AnyObject {
    /// The active per-workspace remote session coordinator, or `nil` when the
    /// remote connection is not established.
    var activeRemoteSessionCoordinator: RemoteSessionCoordinator? { get }

    /// True when this workspace is configured for a remote connection.
    var hostIsRemoteWorkspace: Bool { get }

    /// The controlling-terminal device name per panel id, the input to a
    /// port-scan TTY sync.
    var hostSurfaceTTYNames: [UUID: String] { get }

    /// The live remote configuration, or `nil` when the workspace is local.
    var hostRemoteConfiguration: WorkspaceRemoteConfiguration? { get }

    /// True while a detach-driven close transaction is in flight (the
    /// session-ended marking is suppressed during a detach so the relay port is
    /// not reclaimed under the moved surface).
    var hostIsDetachingCloseTransaction: Bool { get }

    /// The set of surface ids currently tracked as active remote terminals.
    var hostActiveRemoteTerminalSurfaceIds: Set<UUID> { get }

    /// The set of surface ids whose persistent remote PTY attach has ended but
    /// whose surface is kept open (preserve-after-exit).
    var hostEndedPersistentRemotePTYAttachSurfaceIds: Set<UUID> { get }

    /// The set of surface ids whose child exit is pending a workspace-demotion
    /// decision.
    var hostPendingRemoteTerminalChildExitSurfaceIds: Set<UUID> { get }

    /// Marks a remote terminal session as ended for one surface, optionally
    /// scheduling reclaim of its SSH relay port. Faithful forward to the
    /// workspace's session-ended bookkeeping.
    func hostMarkRemoteTerminalSessionEnded(surfaceId: UUID, relayPort: Int?)
}
