import CmuxWorkspaces
import Foundation

@MainActor
extension TabManager {
    /// Applies a Group By choice made in the sidebar Views menu or the command
    /// palette. Grouping only draws in the default workspaces sidebar, so the
    /// choice also switches away from a custom or extension sidebar view;
    /// otherwise picking a mode would look like it did nothing. Socket and CLI
    /// callers set `sidebarGroupBy.mode` directly and leave the view alone.
    func selectSidebarGroupBy(_ mode: SidebarGroupByMode) {
        sidebarGroupBy.mode = mode
        let selection = CmuxExtensionSidebarSelection.self
        let persisted = UserDefaults.standard.string(forKey: selection.defaultsKey) ?? selection.defaultProviderId
        if persisted != selection.defaultProviderId {
            selection.setProviderId(selection.defaultProviderId)
        }
    }

    /// What the sidebar draws in an automatic Group By mode, or nil in manual
    /// mode. Built on demand for keyboard and click actions, never from a body.
    func automaticSidebarGroupingProjection() -> SidebarWorkspaceGroupingProjection? {
        let mode = sidebarGroupBy.mode
        guard mode.isAutomatic else { return nil }
        let notificationStore = TerminalNotificationStore.shared
        return SidebarWorkspaceGroupingProjection(
            tabs: tabs,
            manualGroups: workspaceGroups,
            mode: mode,
            collapsedSectionKeys: sidebarGroupBy.collapsedSectionKeys,
            automaticInputs: tabs.map { workspace in
                SidebarAutoGroupingInput(
                    workspace: workspace,
                    mode: mode,
                    unreadCount: { notificationStore.unreadCount(forTabId: $0) }
                )
            }
        )
    }

    /// Shift-click range in an automatic Group By mode: the drawn, visible
    /// rows between two `tabs` indexes, inclusive. Nil in manual mode, where
    /// callers keep their `tabs`-order range.
    func automaticSidebarRangeIds(betweenTabIndex first: Int, and second: Int) -> [UUID]? {
        guard let projection = automaticSidebarGroupingProjection(),
              tabs.indices.contains(first), tabs.indices.contains(second) else { return nil }
        let drawnIds = SidebarWorkspaceRenderItem.numberedWorkspaceIds(from: projection.renderItems)
        guard let clicked = drawnIds.firstIndex(of: tabs[second].id) else { return [] }
        // The range anchor may sit in a collapsed section; then only the
        // clicked row is selected.
        guard let anchor = drawnIds.firstIndex(of: tabs[first].id) else { return [drawnIds[clicked]] }
        return Array(drawnIds[min(anchor, clicked)...max(anchor, clicked)])
    }

    /// Group-scoped workspace cycling while an automatic Group By mode shows:
    /// the drawn section of the focused workspace, in drawn order. Nil for
    /// window-wide cycling or in manual mode, where the caller keeps the
    /// manual group behavior.
    func automaticSidebarSectionCycleDestination(
        from workspaceId: UUID,
        direction: WorkspaceCycleDirection,
        scope: WorkspaceCycleScope
    ) -> UUID? {
        guard case .focusedGroupMembers = scope,
              let projection = automaticSidebarGroupingProjection(),
              let sectionId = projection.groupIdByWorkspaceId[workspaceId] ?? nil,
              let members = projection.memberWorkspaceIdsByGroupId[sectionId],
              let index = members.firstIndex(of: workspaceId) else { return nil }
        let offset = direction == .next ? 1 : members.count - 1
        return members[(index + offset) % members.count]
    }

    /// Collapses or expands the focused workspace's automatic section.
    /// Returns false in manual mode so the manual group shortcut runs instead.
    func toggleFocusedAutomaticSidebarSectionCollapsed() -> Bool {
        guard let selectedTabId,
              let projection = automaticSidebarGroupingProjection(),
              let sectionId = projection.groupIdByWorkspaceId[selectedTabId] ?? nil,
              let sectionKey = projection.automaticSectionKeyByGroupId[sectionId] else { return false }
        sidebarGroupBy.toggleCollapsed(sectionKey: sectionKey)
        return true
    }
}
