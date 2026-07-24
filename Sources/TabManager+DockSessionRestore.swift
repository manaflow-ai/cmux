import Foundation

extension TabManager {
    func restoreWorkspaceDockSessionSnapshots(
        from snapshot: SessionTabManagerSnapshot,
        excludingStableIdentities: Set<UUID>
    ) {
        let pairs = restoredSessionWorkspacePairs(from: snapshot)
        var workspacesByOriginalId: [UUID: Workspace] = [:]
        for pair in pairs {
            if let originalId = pair.snapshot.workspaceId {
                workspacesByOriginalId[originalId] = pair.workspace
            }
        }
        for pair in pairs {
            guard let dockSnapshot = pair.snapshot.dock else { continue }
            pair.workspace.dockSplit.restoreSessionSnapshot(
                dockSnapshot,
                excludingStableIdentities: excludingStableIdentities,
                sourceWorkspaceResolver: { workspacesByOriginalId[$0] }
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
