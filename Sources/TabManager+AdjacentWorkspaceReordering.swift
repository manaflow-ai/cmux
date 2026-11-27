import Foundation

/// Shared adjacent workspace-reorder entrypoints for shortcuts, menus, and automation.
extension TabManager {
    /// Reorders one workspace by a relative offset. The existing coordinator
    /// clamps the result to the workspace's pinned or unpinned tier.
    @discardableResult
    func reorderWorkspace(tabId: UUID, by offset: Int) -> Bool {
        guard let currentIndex = tabs.firstIndex(where: { $0.id == tabId }) else { return false }
        return reorderWorkspace(tabId: tabId, toIndex: currentIndex + offset)
    }

    /// Reorders the selected workspace while preserving its selection.
    @discardableResult
    func moveSelectedWorkspace(by offset: Int) -> Bool {
        guard let workspace = selectedWorkspace,
              reorderWorkspace(tabId: workspace.id, by: offset) else { return false }
        selectWorkspace(workspace)
        return true
    }
}
