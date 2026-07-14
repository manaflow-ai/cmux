import Foundation

extension TabManager {
    /// Move the selected workspace by a relative number of sidebar positions.
    @discardableResult
    func moveSelectedWorkspace(by offset: Int) -> Bool {
        guard offset != 0,
              let workspace = selectedWorkspace,
              let currentIndex = tabs.firstIndex(where: { $0.id == workspace.id }) else { return false }
        let targetIndex = currentIndex + offset
        guard tabs.indices.contains(targetIndex),
              reorderWorkspace(tabId: workspace.id, toIndex: targetIndex) else { return false }
        selectWorkspace(workspace)
        return true
    }

    /// Move the selected surface within its focused pane while preserving focus.
    @discardableResult
    func moveSelectedSurface(by offset: Int) -> Bool {
        selectedWorkspace?.moveSelectedSurface(by: offset) ?? false
    }
}
