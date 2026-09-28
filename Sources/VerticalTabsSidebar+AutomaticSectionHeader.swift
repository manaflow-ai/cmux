import AppKit
import SwiftUI

extension VerticalTabsSidebar {
    /// Header actions for a derived automatic Group By section.
    ///
    /// A section is not a manual group: clicking its header or chevron only
    /// collapses it, and every group-editing action is inert (the header views
    /// also hide or disable those controls). Nothing here can reach a real
    /// `WorkspaceGroup` or reorder `tabs` through the synthetic group id.
    @MainActor
    func makeAutomaticSectionHeaderActions(sectionKey: String) -> SidebarGroupHeaderRowActions {
        let tabManager = self.tabManager
        let toggleCollapsed: () -> Void = { [weak tabManager] in
            tabManager?.sidebarGroupBy.toggleCollapsed(sectionKey: sectionKey)
        }
        return SidebarGroupHeaderRowActions(
            onToggleCollapsed: toggleCollapsed,
            onFocusAnchor: { _ in toggleCollapsed() },
            onTapPlus: {},
            onRunResolvedItem: { _ in },
            onRename: {},
            onTogglePinned: {},
            onMarkRead: {},
            onMarkUnread: {},
            onClearLatestNotifications: {},
            onMarkAllRead: {},
            onMarkAllUnread: {},
            onUngroup: {},
            onDelete: {},
            onEditConfig: {},
            onOpenDocs: {
                SidebarWorkspaceGroupConfigOpener.openWorkspaceGroupsDocs()
            }
        )
    }
}
