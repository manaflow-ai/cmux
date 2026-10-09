import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSidebar

/// New workspace groups and their name editors in one window (cx-rcby):
/// New Group never stacks a second group on workspaces that already are
/// one, and a group made with no member lives only while its editor is
/// open. A namespace beside SidebarBridge (the bridge type is at the
/// god-file limit).
@MainActor
struct SidebarGroupFlow {
    let bridge: SidebarBridge

    private var editor: PersonalGroupEditorState { bridge.groupEditor }

    /// A new group with no member, its name editor open; it goes when the
    /// editor closes while it is still empty (`groupEditorEnded`).
    func newEmptyGroup(name: String) {
        guard let state = bridge.state else { return }
        // Before personal state loads (or on a daemon without it) the intent waits or is refused like any group intent.
        guard bridge.usesPersonalOrganization else {
            return bridge.handle(.createGroup(CmuxNextSidebar.GroupID.make(), name: name, color: .grey, workspaces: []))
        }
        let room = state.profileID, v2 = bridge.statePersonal, home = bridge.services.machines.local, id = WorkspaceGroupID(rawValue: CmuxNextSidebar.GroupID.make().rawValue)
        // The first palette color no group uses yet (never blue or grey, GroupColor.automatic).
        let color = GroupColor.automatic(used: Set(home.store.personal.groups.compactMap(\.color))) ?? .grey
        let flow = self
        Task {
            let created = await home.request("create-personal-group") { connection -> WorkspaceGroupID in
                v2 ? WorkspaceGroupID(rawValue: try await connection.state.createWorkspaceGroup(
                    name: SidebarGroup.named(name), room: room.rawValue, color: color.rawValue).id)
                    : try await connection.createPersonalGroup(name: SidebarGroup.named(name), id: id, room: room, color: color.rawValue).id
            }
            guard let created else { return flow.bridge.resync() }
            flow.editor.explicit.insert(created)
            flow.editGroup(created)
        }
    }

    /// A new group of `ids` made by an action (New Workspace Group, Group
    /// Selected, Move to New Group, New Workspace in New Group). Workspaces
    /// that already are one whole group get no second group when a person
    /// asks without a name: that group's name editor opens (repeated New
    /// Group, cx-rcby). Automation, and a person who names the group, get
    /// the group they asked for; the group it empties goes.
    /// A person's new group gets the next palette color and its editor
    /// opens on it (the Chrome flow).
    func newGroup(of ids: [SidebarWorkspaceID], name: String, byUser: Bool) {
        if byUser, name.isEmpty, bridge.usesPersonalOrganization, let whole = bridge.life.whole(bridge.placements(ids)) { return editGroup(whole) }
        let id = CmuxNextSidebar.GroupID.make()
        let used = Set(bridge.services.machines.local.store.personal.groups.compactMap(\.color))
        bridge.handle(.createGroup(id, name: name, color: byUser ? GroupColor.automatic(used: used) ?? .grey : .grey, workspaces: ids))
        if byUser, name.isEmpty, bridge.model.group(id) != nil { editGroup(WorkspaceGroupID(rawValue: id.rawValue)) }
    }

    /// Opens `group`'s name editor now, or once the sidebar shows it.
    func editGroup(_ group: WorkspaceGroupID) {
        // One editor at a time: a group made empty that loses its turn goes.
        if let dropped = editor.pending, dropped != group { endUnedited(dropped) }
        editor.pending = group
        openPendingEditor()
    }

    /// Called after each sidebar update: opens a waiting group editor.
    func openPendingEditor() {
        guard let pending = editor.pending, bridge.model.group(CmuxNextSidebar.GroupID(pending.rawValue)) != nil else { return }
        editor.pending = nil
        let id = CmuxNextSidebar.GroupID(pending.rawValue)
        bridge.container.beginRename(group: id)
        // No editor came up (a drag, a row out of view): a group made empty does not wait for one.
        if bridge.container.sidebarView.editingGroup != id { endUnedited(pending) }
    }

    /// A group made empty whose editor never opened: it goes if still empty.
    private func endUnedited(_ group: WorkspaceGroupID) {
        editorEnded(group)
    }

    /// A group's name editor closed: a group made empty goes if it still is.
    func editorEnded(_ group: WorkspaceGroupID) {
        guard editor.explicit.remove(group) != nil else { return }
        let bridge = bridge
        bridge.life.deleteIfEmpty(group, failed: { bridge.resync() })
    }

    /// Keeps the sidebar's optimistic rows until an organization change's
    /// commands have all landed, then shows daemon truth once: a new
    /// group's create, place and delete commits each send a snapshot, and
    /// showing them one by one made the group jump (it arrived empty, its
    /// member snapped back, then moved in). Returns the release.
    func holdRows() -> @MainActor () -> Void {
        editor.rowHolds += 1
        return { [weak bridge = self.bridge] in
            guard let bridge else { return }
            bridge.groupEditor.rowHolds -= 1
            if bridge.groupEditor.rowHolds == 0 { bridge.resync() }
        }
    }

    // MARK: The group editor's rows

    /// The editor's action rows run through the action registry with the
    /// group as their target, the same path as the palette, menus and CLI.
    func wireEditor() {
        let sidebar = bridge.container.sidebarView
        sidebar.groupEditorItems = { [weak bridge = self.bridge] _ in bridge.map { SidebarGroupFlow(bridge: $0).editorItems() } ?? SidebarView.standardGroupEditorItems() }
        sidebar.onGroupEditorItem = { [weak bridge = self.bridge] group, item in
            guard let bridge else { return }
            SidebarGroupFlow(bridge: bridge).performEditorItem(group, item)
        }
    }

    /// The standard rows with each action's current shortcut.
    private func editorItems() -> [[SidebarGroupEditorItem]] {
        let registry = bridge.services.registry
        return SidebarView.standardGroupEditorItems().map { section in
            section.map { item in
                var item = item
                item.shortcut = registry.shortcutDisplay(for: ActionID(rawValue: item.id))
                return item
            }
        }
    }

    private func performEditorItem(_ group: CmuxNextSidebar.GroupID, _ item: String) {
        // A person acted on the group: a group made empty is no longer ended
        // by closing the editor (New Workspace in Group fills it).
        editor.explicit.remove(WorkspaceGroupID(rawValue: group.rawValue))
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .workspaceGroup, id: group.rawValue), origin: .user)
        _ = bridge.services.registry.perform(ActionID(rawValue: item), invocation: invocation)
    }
}
