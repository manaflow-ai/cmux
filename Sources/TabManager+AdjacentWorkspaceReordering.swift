import Foundation

/// Shared adjacent workspace-reorder entrypoints for shortcuts, menus, and automation.
extension TabManager {
    /// Reorders one workspace by a relative offset. The existing coordinator
    /// clamps the result to the workspace's pinned or unpinned tier.
    @discardableResult
    func reorderWorkspace(tabId: UUID, by offset: Int) -> Bool {
        guard let currentIndex = tabs.firstIndex(where: { $0.id == tabId }),
              let plan = workspaceReordering.workspaceReorderPlan(
                tabId: tabId,
                toIndex: currentIndex + offset
              ),
              plan.fromIndex != plan.toIndex else {
            return false
        }
        return reorderWorkspace(tabId: tabId, toIndex: currentIndex + offset)
    }

    /// Whether a relative reorder would move the explicit workspace after
    /// pin-tier and group constraints are applied.
    func canReorderWorkspace(tabId: UUID, by offset: Int) -> Bool {
        guard let currentIndex = tabs.firstIndex(where: { $0.id == tabId }),
              let plan = workspaceReordering.workspaceReorderPlan(
                tabId: tabId,
                toIndex: currentIndex + offset
              ) else {
            return false
        }
        return plan.fromIndex != plan.toIndex
    }

    /// Moves one explicit workspace to the top of its legal pin/group tier
    /// and reports whether the authoritative order changed.
    @discardableResult
    func moveWorkspaceToTop(tabId: UUID) -> Bool {
        guard tabs.contains(where: { $0.id == tabId }) else { return false }
        let previousOrder = tabs.map(\.id)
        moveTabToTop(tabId)
        return tabs.map(\.id) != previousOrder
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
