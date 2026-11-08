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
        let originalWorkspaceIds = pairs.map(\.snapshot.workspaceId)
        for (dockOwnerIndex, pair) in pairs.enumerated() {
            guard let dockSnapshot = pair.snapshot.dock else { continue }
            pair.workspace.dockSplit?.restoreSessionSnapshot(
                dockSnapshot,
                excludingStableIdentities: excludingStableIdentities,
                deferBrowserPanels: deferBrowserPanels,
                sourceWorkspaceResolver: { sourceWorkspaceId in
                    Self.dockSourceWorkspaceIndex(
                        originalWorkspaceIds: originalWorkspaceIds,
                        dockOwnerIndex: dockOwnerIndex,
                        sourceWorkspaceId: sourceWorkspaceId
                    ).map { pairs[$0].workspace }
                }
            )
        }
    }

    func restoredSessionWorkspace(
        originalId: UUID,
        from snapshot: SessionTabManagerSnapshot
    ) -> Workspace? {
        let pairs = restoredSessionWorkspacePairs(from: snapshot)
        return Self.dockSourceWorkspaceIndex(
            originalWorkspaceIds: pairs.map(\.snapshot.workspaceId),
            dockOwnerIndex: nil,
            sourceWorkspaceId: originalId
        ).map { pairs[$0].workspace }
    }

    /// The restored workspace a transferred Dock panel is rebuilt through.
    ///
    /// A persisted workspace ID normally never repeats. An imported, edited or
    /// corrupted session file can repeat one, and restore reminted every copy
    /// after the first. Among copies, the workspace whose Dock holds the panel
    /// wins (its snapshot is the one that carries the panel), then the first
    /// copy, which is what the window Dock resolves to as well.
    nonisolated static func dockSourceWorkspaceIndex(
        originalWorkspaceIds: [UUID?],
        dockOwnerIndex: Int?,
        sourceWorkspaceId: UUID
    ) -> Int? {
        if let dockOwnerIndex,
           originalWorkspaceIds.indices.contains(dockOwnerIndex),
           originalWorkspaceIds[dockOwnerIndex] == sourceWorkspaceId {
            return dockOwnerIndex
        }
        return originalWorkspaceIds.firstIndex { $0 == sourceWorkspaceId }
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
