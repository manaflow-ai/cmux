import Foundation

extension cmuxApp {
    /// Resolves a workspace's current sidebar position for command enablement.
    func selectedWorkspaceIndex(in manager: TabManager, workspaceId: UUID) -> Int? {
        manager.tabs.firstIndex { $0.id == workspaceId }
    }
}
