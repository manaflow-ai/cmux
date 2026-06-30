import CmuxSidebar
import CmuxWorkspaces

extension VerticalTabsSidebar {
    /// Projects the window focus-history stack into custom-sidebar rows.
    func customSidebarRecentFocusSnapshots() -> [CustomSidebarRecentFocusSnapshot] {
        let back = tabManager.focusHistoryMenuSnapshot(direction: .back, maxItemCount: nil)
        let forward = tabManager.focusHistoryMenuSnapshot(direction: .forward, maxItemCount: nil)
        return FocusHistoryMenuSnapshot.recentlyFocused(back: back, forward: forward, maxItemCount: 16)
            .items
            .map { item in
                CustomSidebarRecentFocusSnapshot(
                    workspaceId: item.entry.workspaceId,
                    panelId: tabManager.focusHistoryNavigation.resolvedFocusHistoryPanelId(for: item.entry),
                    workspaceTitle: item.workspaceTitle,
                    panelTitle: item.panelTitle,
                    position: item.position == .older ? "older" : "newer",
                    focusedAt: item.focusedAt
                )
            }
    }
}
