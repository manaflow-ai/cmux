import Foundation

extension Workspace {
    /// Restores a valid Cloud binding, normalizing its optional remote workspace identity.
    nonisolated static func restoredCloudVMBinding(from snapshot: SessionCloudVMBindingSnapshot?) -> WorkspaceCloudVMBinding? {
        guard let snapshot, let vmID = WorkspaceCloudVMBinding.normalizedVMID(snapshot.vmID) else { return nil }
        let remote = snapshot.remoteWorkspaceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkspaceCloudVMBinding(vmID: vmID, isBase: snapshot.isBase, remoteWorkspaceID: remote?.isEmpty == false ? remote : nil)
    }

    /// Re-adopts a persisted panel identity unless it is still live elsewhere.
    func adoptPersistedStableSurfaceId(from snapshot: SessionPanelSnapshot, panelId: UUID) {
        if let stableSurfaceId = snapshot.stableSurfaceId,
           sessionRestoreIdentityExclusions.shouldAdopt(stableSurfaceId),
           let panel = panels[panelId] {
            panel.adoptStableSurfaceId(stableSurfaceId)
        }
    }

    func restoreClosedPanel(
        _ entry: ClosedPanelHistoryEntry,
        excludingStableIdentities: Set<UUID>
    ) -> UUID? {
        sessionRestoreIdentityExclusions.beginRestore(excluding: excludingStableIdentities)
        defer { sessionRestoreIdentityExclusions.endRestore() }
        return restoreClosedPanel(entry)
    }
}
