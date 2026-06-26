import CmuxCore
import CmuxRemoteSession
import CmuxRemoteWorkspace
import Foundation

/// `Workspace` is the live host for its `RemoteRelaySessionCoordinator`. The
/// coordinator (in `CmuxRemoteWorkspace`) owns the reverse-CLI-relay alias maps
/// and the per-panel remote-PTY session-id store, plus the snapshot/attach-match
/// session-id derivations; this witness reproduces the small slice of live
/// workspace state those bodies read or push: the workspace id, the live remote
/// configuration, the active-remote-terminal surface set, the session-id
/// normalization (owned by the surface-creation coordinator), and the push of
/// the alias maps to the active remote session controller (a `CmuxRemoteSession`
/// type the workspace holds).
///
/// This mirrors the sibling `Workspace+RemoteSurfaceHosting`: the lifted
/// coordinator's live seam conformance lives in its own app-target file so
/// `Workspace.swift` drains the bookkeeping instead of trading it for inline
/// seam glue. `hostRemoteConfiguration` and `hostActiveRemoteTerminalSurfaceIds`
/// are already witnessed for `RemoteSurfaceHosting` in
/// `Workspace+RemoteSurfaceHosting.swift`, so the same computed properties
/// satisfy this protocol too. The coordinator is held by `Workspace` and
/// references this host weakly, so there is no retain cycle.
extension Workspace: RemoteRelaySessionHosting {
    var hostWorkspaceID: UUID {
        id
    }

    func hostNormalizedRemotePTYSessionID(_ value: String?) -> String? {
        surfaceCreation.normalizedRemotePTYSessionID(value)
    }

    func hostUpdateRemoteRelayIDAliases(
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID]
    ) {
        remoteSessionController?.updateRemoteRelayIDAliases(
            workspaceAliases: workspaceAliases,
            surfaceAliases: surfaceAliases
        )
    }
}
