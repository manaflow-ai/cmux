import Foundation

extension SessionWindowSnapshot {
    func hasUsableRestoredContent(
        restoredPanelIdsByWorkspaceIndex: [[UUID: UUID]],
        hasLivePanels: Bool
    ) -> Bool {
        guard hasLivePanels else { return false }
        guard hasRestorablePanels else { return true }
        return restoredPanelIdsByWorkspaceIndex.contains { !$0.isEmpty }
    }
}
