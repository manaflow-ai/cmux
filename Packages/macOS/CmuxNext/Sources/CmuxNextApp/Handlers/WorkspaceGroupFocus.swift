import CmuxNextSidebar

/// Going to a sidebar group (Go to Workspace's group rows, Next and Previous
/// Workspace Group): the group's first workspace is shown. A collapsed group
/// opens first so the shown workspace's row is visible; an empty saved group
/// reopens as a click on its header does.
enum WorkspaceGroupFocus {
    /// What going to `group` does.
    struct Plan: Equatable {
        /// The group is collapsed and opens.
        var expands: Bool
        /// The workspace to show, nil when the group has none ready.
        var workspace: CmuxNextSidebar.WorkspaceID?
        /// An empty saved group reopens (its header's click).
        var reopens: Bool
    }

    /// The first workspace of `group` that is not still being created.
    static func firstWorkspace(of group: SidebarGroup) -> CmuxNextSidebar.WorkspaceID? {
        group.workspaces.first { !$0.rowState.isPending }?.id
    }

    static func plan(for group: SidebarGroup) -> Plan {
        let reopens = group.isPinned && group.workspaces.isEmpty && group.items.isEmpty
        let workspace = firstWorkspace(of: group)
        return Plan(expands: group.isCollapsed && workspace != nil, workspace: workspace, reopens: reopens)
    }

    /// Goes to group `id` in the active window's sidebar. Returns false when
    /// the sidebar has no such group.
    @discardableResult
    static func go(to id: CmuxNextSidebar.GroupID, services: AppServices) -> Bool {
        guard let window = services.windows.active, let group = window.sidebar.model.group(id) else { return false }
        let plan = plan(for: group)
        if plan.reopens { window.sidebar.handle(.openGroup(id)) }
        if plan.expands { window.sidebar.handle(.toggleCollapse(.group(id))) }
        if let workspace = plan.workspace { services.windows.show(workspaceID: workspace.rawValue, in: window.state) }
        return true
    }
}
