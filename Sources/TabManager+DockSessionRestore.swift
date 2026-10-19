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
        let workspacesById = Dictionary(pairs.map { ($0.workspace.id, $0.workspace) }, uniquingKeysWith: { first, _ in first })
        var restoredIdsByOriginalId: [UUID: [UUID]] = [:]
        for pair in pairs {
            if let originalId = pair.snapshot.workspaceId {
                restoredIdsByOriginalId[originalId, default: []].append(pair.workspace.id)
            }
        }
        for pair in pairs {
            guard let dockSnapshot = pair.snapshot.dock else { continue }
            pair.workspace.dockSplit?.restoreSessionSnapshot(
                dockSnapshot,
                excludingStableIdentities: excludingStableIdentities,
                deferBrowserPanels: deferBrowserPanels,
                sourceWorkspaceResolver: { originalId in
                    let restoredIds = restoredIdsByOriginalId[originalId] ?? []
                    // Legacy snapshots cannot distinguish duplicate source IDs. Prefer
                    // this Dock's owner when it matches, otherwise the first saved source.
                    // Keep the original ID in the snapshot for remote session restoration.
                    let restoredId = restoredIds.contains(pair.workspace.id)
                        ? pair.workspace.id
                        : restoredIds.first
                    return restoredId.flatMap { workspacesById[$0] }
                }
            )
        }
    }

    func restoredSessionWorkspace(
        originalId: UUID,
        from snapshot: SessionTabManagerSnapshot
    ) -> Workspace? {
        restoredSessionWorkspacePairs(from: snapshot).first {
            $0.snapshot.workspaceId == originalId
        }?.workspace
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
