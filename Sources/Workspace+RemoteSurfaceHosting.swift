import CmuxCore
import CmuxRemoteSession
import Foundation

/// `Workspace` is the live host for its `RemoteSurfaceCoordinator`. The
/// coordinator (in `CmuxRemoteSession`) owns the remote *surface* command
/// orchestration (remote PTY bridge list/start/resize/detach, remote port-scan
/// kick/sync/enablement, dropped-file upload) and the child-exit
/// surface-tracking predicates; this witness reproduces the small slice of live
/// workspace state those bodies read or mutate: the active session coordinator,
/// the remote-workspace flag, the per-surface TTY names, the active/ended/
/// pending remote-terminal surface sets, the live remote configuration, the
/// detach-close flag, and the single session-ended mutation.
///
/// This mirrors the publish-side `WorkspaceRemoteSessionHostAdapter`
/// (`RemoteSessionHosting`) and the sibling `Workspace+AgentHibernationHosting`
/// pattern: the lifted coordinator's live seam conformance lives in its own
/// app-target file so `Workspace.swift` drains the orchestration instead of
/// trading it for inline seam glue. The coordinator is held by `Workspace` and
/// references this host weakly, so there is no retain cycle.
extension Workspace: RemoteSurfaceHosting {
    var activeRemoteSessionCoordinator: RemoteSessionCoordinator? {
        remoteSessionController
    }

    var hostIsRemoteWorkspace: Bool {
        isRemoteWorkspace
    }

    var hostSurfaceTTYNames: [UUID: String] {
        surfaceTTYNames
    }

    var hostRemoteConfiguration: WorkspaceRemoteConfiguration? {
        get { remoteConfiguration }
        set { remoteConfiguration = newValue }
    }

    var hostIsDetachingCloseTransaction: Bool {
        isDetachingCloseTransaction
    }

    var hostActiveRemoteTerminalSurfaceIds: Set<UUID> {
        activeRemoteTerminalSurfaceIds
    }

    var hostEndedPersistentRemotePTYAttachSurfaceIds: Set<UUID> {
        endedPersistentRemotePTYAttachSurfaceIds
    }

    var hostPendingRemoteTerminalChildExitSurfaceIds: Set<UUID> {
        pendingRemoteTerminalChildExitSurfaceIds
    }

    func hostMarkRemoteTerminalSessionEnded(surfaceId: UUID, relayPort: Int?) {
        markRemoteTerminalSessionEnded(surfaceId: surfaceId, relayPort: relayPort)
    }
}
