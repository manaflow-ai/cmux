import Foundation

extension SessionWindowSnapshot {
    /// Whether restoring this closed-window snapshot produced usable content,
    /// gating whether the recently-restored window is kept or discarded.
    ///
    /// Returns `false` when no live panels materialized. When the snapshot
    /// carried no restorable panels to begin with, any live panels count as
    /// usable. Otherwise at least one workspace must have actually restored a
    /// panel (a non-empty entry in `restoredPanelIdsByWorkspaceIndex`).
    func hasUsableRestoredContent(
        restoredPanelIdsByWorkspaceIndex: [[UUID: UUID]],
        hasLivePanels: Bool
    ) -> Bool {
        guard hasLivePanels else { return false }
        guard hasRestorablePanels else { return true }
        return restoredPanelIdsByWorkspaceIndex.contains { !$0.isEmpty }
    }
}
