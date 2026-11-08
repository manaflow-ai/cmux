import CmuxNextSidebar
import CmuxNextWindowRules

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
        plan(for: group).workspace
    }

    /// The rule is Rust's (cmux-window-rules `workspaces::group_focus`); nothing happens when the FFI does not answer.
    static func plan(for group: SidebarGroup) -> Plan {
        let rows = group.workspaces.map { (id: $0.id.rawValue, pending: $0.rowState.isPending) }
        guard let plan = WindowRules().groupFocus(collapsed: group.isCollapsed, pinned: group.isPinned, workspaces: rows,
                                                  items: group.items.count) else {
            return Plan(expands: false, workspace: nil, reopens: false)
        }
        return Plan(expands: plan.expands, workspace: plan.workspace.map { CmuxNextSidebar.WorkspaceID($0) }, reopens: plan.reopens)
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
