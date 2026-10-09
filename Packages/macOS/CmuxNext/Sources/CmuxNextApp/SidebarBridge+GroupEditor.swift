import CmuxNextActions
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

    /// A new group of `ids` made by an action. A person's group gets the
    /// next palette color and its editor opens on it (the Chrome flow);
    /// automation keeps the plain grey group it asked for.
    func newGroup(of ids: [SidebarWorkspaceID], name: String, byUser: Bool) {
        // Workspaces that already are one whole group get no second group
        // (repeated New Group, cx-rcby); a person gets that group's editor.
        if usesPersonalOrganization, let whole = life.whole(placements(ids)) {
            if byUser { editGroup(whole) }
            return
        }
        let id = CmuxNextSidebar.GroupID.make()
        let used = Set(services.machines.local.store.personal.groups.compactMap(\.color))
        let color = byUser ? GroupColor.automatic(used: used) ?? .grey : .grey
        handle(.createGroup(id, name: name, color: color, workspaces: ids))
        if byUser, name.isEmpty, model.group(id) != nil { editGroup(WorkspaceGroupID(rawValue: id.rawValue)) }
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
