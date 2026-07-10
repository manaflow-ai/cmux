import Foundation

enum ClosedWindowRestoreValidation {
    static func hasUsableRestoredContent(
        snapshot: SessionWindowSnapshot,
        restoredPanelIdsByWorkspaceIndex: [[UUID: UUID]],
        hasLivePanels: Bool
    ) -> Bool {
        guard hasLivePanels else { return false }
        guard snapshot.hasRestorablePanels else { return true }
        return restoredPanelIdsByWorkspaceIndex.contains { !$0.isEmpty }
    }
}
