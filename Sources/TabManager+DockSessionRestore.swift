import CmuxWorkspaces
import Foundation

extension TabManager {
    /// Restores each workspace's persisted Dock after workspace topology exists.
    ///
    /// Deferred browser panels are passed through without constructing WebKit
    /// until the corresponding Dock pane becomes visible.
    func restoreWorkspaceDockSessionSnapshots(
        from snapshot: SessionTabManagerSnapshot,
        excludingStableIdentities: Set<UUID>,
        deferBrowserPanels: Bool = false
    ) {
        let pairs = restoredSessionWorkspacePairs(from: snapshot)
        let resolver = DockSourceWorkspaceResolver(
            originalWorkspaceIds: pairs.map(\.snapshot.workspaceId)
        )
        for (dockOwnerIndex, pair) in pairs.enumerated() {
            guard let dockSnapshot = pair.snapshot.dock else { continue }
            pair.workspace.dockSplit?.restoreSessionSnapshot(
                dockSnapshot,
                excludingStableIdentities: excludingStableIdentities,
                deferBrowserPanels: deferBrowserPanels,
                sourceWorkspaceResolver: { sourceWorkspaceId in
                    resolver.workspaceIndex(
                        sourceWorkspaceId: sourceWorkspaceId,
                        dockOwnerIndex: dockOwnerIndex
                    ).map { pairs[$0].workspace }
                }
            )
        }
    }

    /// Resolves a window Dock panel's persisted source workspace ID to a
    /// restored workspace. Built once per window Dock restore, so each panel
    /// lookup is constant time.
    func restoredSessionWorkspaceResolver(
        from snapshot: SessionTabManagerSnapshot
    ) -> (UUID) -> Workspace? {
        let pairs = restoredSessionWorkspacePairs(from: snapshot)
        let resolver = DockSourceWorkspaceResolver(
            originalWorkspaceIds: pairs.map(\.snapshot.workspaceId)
        )
        return { originalId in
            resolver.workspaceIndex(sourceWorkspaceId: originalId)
                .map { pairs[$0].workspace }
        }
    }

    private func restoredSessionWorkspacePairs(
        from snapshot: SessionTabManagerSnapshot
    ) -> [(snapshot: SessionWorkspaceSnapshot, workspace: Workspace)] {
        let (normalizedSnapshots, _) = Self.normalizedCloudVMSessionRestoreWorkspaces(
            snapshot.workspaces.prefix(SessionPersistencePolicy.maxWorkspacesPerWindow),
            selectedWorkspaceIndex: snapshot.selectedWorkspaceIndex
        )
        return Array(zip(
            normalizedSnapshots.prefix(SessionPersistencePolicy.maxWorkspacesPerWindow),
            tabs
        ))
    }
}
