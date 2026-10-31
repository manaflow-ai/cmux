import Foundation

extension SidebarIntent {
    /// The catalog action this sidebar change stands for when its save fails (#26382), and the notice's title when
    /// the action's own does not name the change (a drag, a reorder: "Move"). The App shows "<change> did not apply:
    /// <reason>" with it, the notice of a failed action effect.
    @MainActor public var saveAction: (id: String, title: String?) {
        switch self {
        case .renameGroup: ("workspaceGroup.rename", nil)
        case .setGroupColor: ("workspaceGroup.setColor", nil)
        case .setGroupIcon: ("workspaceGroup.setIcon", nil)
        case .setGroupPinned: ("workspaceGroup.togglePin", nil)
        case .ungroup: ("workspaceGroup.ungroup", nil)
        case .closeGroup: ("workspaceGroup.closeWorkspaces", nil)
        case .toggleCollapse: ("toggleFocusedWorkspaceGroupCollapsed", nil)
        case .createGroup: ("newWorkspaceGroup", nil)
        case .rename: ("renameWorkspace", nil)
        case .setColor: ("palette.workspaceColor", nil)
        case .setPinned: ("palette.toggleWorkspacePin", nil)
        case .close: ("closeWorkspace", nil)
        case .setIcon: ("workspace.setIcon", nil)
        case .reorderProfile: ("space.move", nil)
        default: ("moveWorkspaceToGroup", SidebarDocStore.moveTitle)
        }
    }
}
