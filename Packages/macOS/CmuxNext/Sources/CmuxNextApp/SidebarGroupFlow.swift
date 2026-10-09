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
        if bridge.container.editingGroup != id { endUnedited(pending) }
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

    // MARK: Organization intents that end groups

    /// `.move`: the workspaces join `group`; a group they leave empty goes.
    func move(_ ids: [SidebarWorkspaceID], into group: CmuxNextSidebar.GroupID, _ intent: SidebarIntent) {
        let id = WorkspaceGroupID(rawValue: group.rawValue), members = bridge.placements(ids)
        let life = bridge.life, ending = life.emptied(by: members, into: id)
        // A pending edit until the store holds the move (cx-odqn): no recompute in between shows the old group.
        let (failed, applied) = bridge.rows.outcome(bridge.rows.add(intent), resync: { bridge.resync() })
        life.commit("set-personal-workspace", ending: ending, recheck: { life.emptied(by: members, into: id) },
                    failed: failed, applied: applied) { connection in
            for workspace in members {
                try await connection.state.placePersonalWorkspace(session: workspace.session, key: workspace.key, resource: workspace.resource,
                                                                  group: .set(id))
            }
        }
    }

    /// `.createGroup`: the group forms where the model formed it; a group its
    /// members leave empty goes.
    func create(_ group: CmuxNextSidebar.GroupID, name: String, color: GroupColor, _ ids: [SidebarWorkspaceID], collapsed: Bool,
                room: ProfileID, _ intent: SidebarIntent) {
        let id = WorkspaceGroupID(rawValue: group.rawValue), members = bridge.placements(ids), v2 = bridge.statePersonal
        let life = bridge.life, ending = life.emptied(by: members, into: nil)
        // A pending edit until the store holds the new group (cx-odqn): the
        // create, place and delete echoes never show the group empty or the
        // member snapping back; the header view carries on under the daemon's id.
        let (settleFailed, applied) = bridge.rows.outcome(bridge.rows.add(intent), resync: { bridge.resync() })
        let editor = editor
        let failed: @MainActor () -> Void = {
            // Edits made meanwhile go with the group that was not made.
            for edit in editor.creating.removeValue(forKey: id) ?? [] { bridge.rows.settle(edit.token) }
            settleFailed()
        }
        // Mixed order: the new group's place where the model formed it,
        // set before members join so it never shows at the end first.
        let place = bridge.usesMixedOrder && v2
            ? PersonalSidebarPlanner(machines: bridge.services.machines).groupPlacement(of: group, in: bridge.model.sections)
            : PersonalSidebar.GroupPlacement()
        let move = place.move, top = place.topIndex, flow = self
        editor.creating[id] = []
        life.commit("create-personal-group", ending: ending, recheck: { life.emptied(by: members, into: nil) }, failed: failed,
                    applied: applied, landed: { created in flow.landed(id, as: created) }) { connection -> WorkspaceGroupID in
            // The v2 operation names the group itself.
            let created = v2 ? WorkspaceGroupID(rawValue: try await connection.state.createWorkspaceGroup(
                name: SidebarGroup.named(name), room: room.rawValue, color: color.rawValue, index: move).id)
                : try await connection.createPersonalGroup(name: SidebarGroup.named(name), id: id, room: room, color: color.rawValue).id
            try await PersonalGroupCreation.finish(created, topIndex: top, collapsed: collapsed, statePersonal: v2, on: connection)
            for workspace in members {
                try await connection.state.placePersonalWorkspace(session: workspace.session, key: workspace.key, resource: workspace.resource,
                                                                  group: .set(created))
            }
            return created
        }
    }

    /// The daemon made the group under `created`: edits made meanwhile go to it.
    private func landed(_ local: WorkspaceGroupID, as created: WorkspaceGroupID) {
        editor.created[local] = created
        guard let pending = editor.creating.removeValue(forKey: local) else { return }
        for edit in pending { send(created, name: edit.name, color: edit.color, edit: edit.token) }
    }

    /// `.renameGroup` / `.setGroupColor`. The editor opens on a new group at
    /// once, under the sidebar's own id: an edit before the daemon made the
    /// group waits for it, and later ones go to the daemon's id.
    func edit(_ group: CmuxNextSidebar.GroupID, name: String? = nil, color: GroupColor? = nil, _ intent: SidebarIntent) {
        // A pending edit until the store holds it, so a recompute (or the
        // pending new group's own edit) never shows the old name or color.
        let token = bridge.rows.add(intent)
        let id = WorkspaceGroupID(rawValue: group.rawValue)
        if editor.creating[id] != nil {
            editor.creating[id]?.append(PersonalGroupEditorState.Edit(name: name, color: color, token: token))
            return
        }
        send(editor.created[id] ?? id, name: name, color: color, edit: token)
    }

    private func send(_ id: WorkspaceGroupID, name: String?, color: GroupColor?, edit: SidebarPendingEdits.Token) {
        let v2 = bridge.statePersonal, bridge = bridge, colorUpdate: FieldUpdate<String> = color.map { .set($0.rawValue) } ?? .unchanged
        bridge.rows.send("update-personal-group", edit: edit, on: bridge.services.machines.local, resync: { bridge.resync() }) { connection in
            if v2 { return try await connection.state.updateWorkspaceGroup(id.rawValue, name: name, color: colorUpdate) }
            try await connection.updatePersonalGroup(id, name: name, color: colorUpdate)
        }
    }

    // MARK: The group editor's rows

    /// The editor's action rows run through the action registry with the
    /// group as their target, the same path as the palette, menus and CLI.
    func wireEditor() {
        let container = bridge.container
        container.groupEditorItems = { [weak bridge = self.bridge] _ in
            bridge.map { SidebarGroupFlow(bridge: $0).editorItems() } ?? SidebarContainerView.standardGroupEditorItems()
        }
        container.onGroupEditorItem = { [weak bridge = self.bridge] group, item in
            guard let bridge else { return }
            SidebarGroupFlow(bridge: bridge).performEditorItem(group, item)
        }
    }

    /// The standard rows with each action's current shortcut.
    private func editorItems() -> [[SidebarGroupEditorItem]] {
        let registry = bridge.services.registry
        return SidebarContainerView.standardGroupEditorItems().map { section in
            section.map { item in
                var item = item
                item.shortcut = registry.shortcutDisplay(for: ActionID(rawValue: item.id))
                return item
            }
        }
    }

    private func performEditorItem(_ group: CmuxNextSidebar.GroupID, _ item: String) {
        // A group made empty that is about to get a member (New Workspace in
        // Group, or an action from its full menu) does not go when the editor closes.
        // Delete, Ungroup and Close end the group themselves (no second delete).
        let local = WorkspaceGroupID(rawValue: group.rawValue)
        if ["workspaceGroup.newWorkspace", SidebarContainerView.moreActionsItem, "workspaceGroup.delete", "workspaceGroup.ungroup",
            "workspaceGroup.closeWorkspaces"].contains(item) {
            editor.explicit.remove(local)
        }
        guard item != SidebarContainerView.moreActionsItem else { return }
        // The daemon's id for a group the sidebar made under its own.
        let target = editor.created[local] ?? local
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .workspaceGroup, id: target.rawValue), origin: .user)
        _ = bridge.services.registry.perform(ActionID(rawValue: item), invocation: invocation)
    }
}
