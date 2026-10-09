import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSidebar

// The workspace group editor's action rows (cx-rcby): the sidebar shows the
// shared group actions; each row runs through the action registry with the
// group as its target, the same path as the palette, menus and the CLI.
extension SidebarBridge {
    func wireGroupEditor() {
        let sidebar = container.sidebarView
        sidebar.groupEditorItems = { [weak self] _ in self?.groupEditorItems() ?? SidebarView.standardGroupEditorItems() }
        sidebar.onGroupEditorItem = { [weak self] group, item in self?.performGroupEditorItem(group, item) }
    }

    /// The standard rows with each action's current shortcut.
    private func groupEditorItems() -> [[SidebarGroupEditorItem]] {
        let registry = services.registry
        return SidebarView.standardGroupEditorItems().map { section in
            section.map { item in
                var item = item
                item.shortcut = registry.shortcutDisplay(for: ActionID(rawValue: item.id))
                return item
            }
        }
    }

    private func performGroupEditorItem(_ group: CmuxNextSidebar.GroupID, _ item: String) {
        // A person acted on the group: a group made empty is no longer ended
        // by closing the editor (New Workspace in Group fills it).
        groupEditor.explicit.remove(WorkspaceGroupID(rawValue: group.rawValue))
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .workspaceGroup, id: group.rawValue), origin: .user)
        _ = services.registry.perform(ActionID(rawValue: item), invocation: invocation)
    }
}
