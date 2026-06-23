internal import CmuxRemoteWorkspace
public import Foundation

/// Relay id-alias bookkeeping for the surface coordinator.
///
/// A remote relay command line carries the snapshot/source workspace and
/// surface ids; on session restore or detached transfer the surface is rebound
/// to a new local id, so the relay command must be rewritten to map the old id
/// to the new one. This extension owns the alias maps (on ``state``), keeps the
/// active session coordinator's copy in sync, and rewrites relay command lines.
/// Faithful lift of the `Workspace` relay-alias methods.
extension RemoteSurfaceCoordinator {
    /// Pushes the current alias maps to the active session coordinator so its
    /// relay rewriting matches the workspace's restored ids. Faithful lift of
    /// `Workspace.syncRemoteRelayIDAliasesToController()`.
    public func syncRemoteRelayIDAliasesToController() {
        host?.activeRemoteSessionCoordinator?.updateRemoteRelayIDAliases(
            workspaceAliases: state.remoteRelayWorkspaceIDAliases,
            surfaceAliases: state.remoteRelaySurfaceIDAliases
        )
    }

    /// Clears all relay id aliases and resyncs the active session coordinator.
    /// Faithful lift of `Workspace.clearRemoteRelayIDAliases()`.
    public func clearRemoteRelayIDAliases() {
        guard !state.remoteRelayWorkspaceIDAliases.isEmpty
            || !state.remoteRelaySurfaceIDAliases.isEmpty else { return }
        state.remoteRelayWorkspaceIDAliases.removeAll()
        state.remoteRelaySurfaceIDAliases.removeAll()
        syncRemoteRelayIDAliasesToController()
    }

    /// Drops surface aliases whose restored id is no longer valid and resyncs.
    /// Faithful lift of `Workspace.pruneRemoteRelaySurfaceAliases(validSurfaceIds:)`.
    public func pruneRemoteRelaySurfaceAliases(validSurfaceIds: Set<UUID>) {
        let nextAliases = state.remoteRelaySurfaceIDAliases.filter { validSurfaceIds.contains($0.value) }
        guard nextAliases != state.remoteRelaySurfaceIDAliases else { return }
        state.remoteRelaySurfaceIDAliases = nextAliases
        syncRemoteRelayIDAliasesToController()
    }

    /// Drops surface aliases that point at `panelId` and resyncs. Faithful lift
    /// of `Workspace.removeRemoteRelaySurfaceAliases(targeting:)`.
    public func removeRemoteRelaySurfaceAliases(targeting panelId: UUID) {
        let nextAliases = state.remoteRelaySurfaceIDAliases.filter { $0.value != panelId }
        guard nextAliases != state.remoteRelaySurfaceIDAliases else { return }
        state.remoteRelaySurfaceIDAliases = nextAliases
        syncRemoteRelayIDAliasesToController()
    }

    /// Records the snapshot→restored id aliases for one surface and resyncs when
    /// either map changed. Faithful lift of
    /// `Workspace.registerRemoteRelayIDAliases(snapshotWorkspaceId:snapshotPanelId:restoredPanelId:)`.
    public func registerRemoteRelayIDAliases(
        snapshotWorkspaceId: UUID?,
        snapshotPanelId: UUID,
        restoredPanelId: UUID
    ) {
        guard let host else { return }
        var didMutate = false
        if let snapshotWorkspaceId, snapshotWorkspaceId != host.hostWorkspaceID {
            if state.remoteRelayWorkspaceIDAliases[snapshotWorkspaceId] != host.hostWorkspaceID {
                state.remoteRelayWorkspaceIDAliases[snapshotWorkspaceId] = host.hostWorkspaceID
                didMutate = true
            }
        }
        if snapshotPanelId != restoredPanelId {
            if state.remoteRelaySurfaceIDAliases[snapshotPanelId] != restoredPanelId {
                state.remoteRelaySurfaceIDAliases[snapshotPanelId] = restoredPanelId
                didMutate = true
            }
        }
        if didMutate {
            syncRemoteRelayIDAliasesToController()
        }
    }

    /// Records the snapshot→restored id aliases parsed from a default SSH PTY
    /// session id. Faithful lift of
    /// `Workspace.registerRemoteRelayIDAliases(remotePTYSessionID:restoredPanelId:)`.
    public func registerRemoteRelayIDAliases(remotePTYSessionID: String, restoredPanelId: UUID) {
        guard let parsed = Self.parsedDefaultSSHPTYSessionID(remotePTYSessionID) else { return }
        registerRemoteRelayIDAliases(
            snapshotWorkspaceId: parsed.workspaceId,
            snapshotPanelId: parsed.panelId,
            restoredPanelId: restoredPanelId
        )
    }

    /// Rewrites a relay command line using this workspace's current alias maps.
    /// Faithful lift of `Workspace.rewriteRemoteRelayCommandLine(_:)`.
    public func rewriteRemoteRelayCommandLine(_ commandLine: Data) -> Data {
        RemoteRelayCommandLineRewriter.rewrite(
            commandLine,
            workspaceAliases: state.remoteRelayWorkspaceIDAliases,
            surfaceAliases: state.remoteRelaySurfaceIDAliases
        )
    }
}
