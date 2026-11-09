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
            return bridge.handle(.createGroup(CmuxNextSidebar.GroupID.make(), name: name, color: SidebarGroup.newTint(in: bridge.model.sections), workspaces: []))
        }
        let room = state.profileID, v2 = bridge.statePersonal, home = bridge.services.machines.local, id = WorkspaceGroupID(rawValue: CmuxNextSidebar.GroupID.make().rawValue),
            color = SidebarGroup.newTint(in: bridge.model.sections)
        let flow = self
        Task {
            let created = await home.request("create-personal-group") { connection -> WorkspaceGroupID in
                v2 ? WorkspaceGroupID(rawValue: try await connection.state.createWorkspaceGroup(
                    name: SidebarGroup.named(name), room: room.rawValue, color: color.wire).id)
                    : try await connection.createPersonalGroup(name: SidebarGroup.named(name), id: id, room: room, color: color.wire).id
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
    /// A new group takes its color from the palette the person chose (`SidebarGroup.newTint`): none under glass, the
    /// default (Leo 2026-10-31: "WHY DOES THIS HAVE A LINE AND COLOR"). A person's also opens its editor (the Chrome
    /// flow). `index` places the group (`SidebarIntent.createGroup`), else it forms at its first member.
    func newGroup(of ids: [SidebarWorkspaceID], name: String, byUser: Bool, index: Int? = nil) {
        let personal = bridge.usesPersonalOrganization, whole = personal ? bridge.life.whole(bridge.placements(ids)) : nil
        guard let plan = SidebarBridgeRules().newGroup(byUser: byUser, unnamed: name.isEmpty, personal: personal, whole: whole != nil) else { return bridge.resync() }
        if plan.editWhole, let whole { return editGroup(whole) }
        let id = CmuxNextSidebar.GroupID.make()
        bridge.handle(.createGroup(id, name: name, color: SidebarGroup.newTint(in: bridge.model.sections), workspaces: ids, index: index))
        if plan.editNew, bridge.model.group(id) != nil { editGroup(WorkspaceGroupID(rawValue: id.rawValue)) }
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
        // On the sidebar document the group shows as its item (`itm_g_<id>`).
        guard let pending = editor.pending, case let id = bridge.model.groupID(personal: pending.rawValue), bridge.model.group(id) != nil else { return }
        editor.pending = nil
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
        bridge.life.deleteIfEmpty(group, failed: bridge.saveFailed(.ungroup(CmuxNextSidebar.GroupID(group.rawValue))))
    }

    // MARK: Organization intents that end groups

    /// `.move`: the workspaces join `group`; a group they leave empty goes.
    func move(_ ids: [SidebarWorkspaceID], into group: CmuxNextSidebar.GroupID, _ intent: SidebarIntent) {
        let id = WorkspaceGroupID(rawValue: group.rawValue), members = bridge.placements(ids)
        let life = bridge.life, ending = life.emptied(by: members, into: id)
        // A pending edit until the store holds the move (cx-odqn): no recompute in between shows the old group.
        let (failed, applied) = bridge.rows.edits.outcome(bridge.rows.edits.add(intent), failed: bridge.saveFailed(intent))
        let writes = life.personal.writes, claim = writes.claim(workspaces: members.map { ($0.session, $0.key.rawValue) })
        life.commit("set-personal-workspace", ending: ending, recheck: { ending.filter(life.isEmptyUnpinned) }, until: claim, failed: failed, applied: applied) { connection in
            for workspace in members { guard await writes.isCurrent(claim, workspace: workspace.session, workspace.key.rawValue) else { continue } // a later move's
                try await connection.state.placePersonalWorkspace(session: workspace.session, key: workspace.key, resource: workspace.resource,
                                                                  group: .set(id))
            }
        }
    }

    /// `.createGroup`: the group forms where the model formed it; a group its
    /// members leave empty goes.
    func create(_ group: CmuxNextSidebar.GroupID, name: String, color: GroupTint, _ ids: [SidebarWorkspaceID], collapsed: Bool,
                room: ProfileID, index: Int? = nil, _ intent: SidebarIntent) {
        let id = WorkspaceGroupID(rawValue: group.rawValue), members = bridge.placements(ids), v2 = bridge.statePersonal
        let life = bridge.life, ending = life.emptied(by: members, into: nil)
        // A pending edit until the store holds the new group (cx-odqn): the
        // create, place and delete echoes never show the group empty or the
        // member snapping back; the header view carries on under the daemon's id.
        let token = bridge.rows.edits.add(intent), (settleFailed, applied) = bridge.rows.edits.outcome(token, failed: bridge.saveFailed(intent))
        let editor = editor
        let failed: @MainActor (ActionWorkFailure) -> Void = { failure in
            // Edits made meanwhile go with the group that was not made.
            for edit in editor.creating.removeValue(forKey: id) ?? [] { bridge.rows.edits.settle(edit.token) }
            bridge.rows.edits.settle(editor.removing.removeValue(forKey: id))
            settleFailed(failure)
        }
        // Mixed order: the new group's place where the model formed it,
        // set before members join so it never shows at the end first.
        let place = bridge.usesMixedOrder && v2
            ? PersonalSidebarPlanner(machines: bridge.services.machines).groupPlacement(of: group, in: bridge.model.sections)
            : PersonalSidebar.GroupPlacement()
        // The sidebar's place wins; else the caller's (New Workspace in New Group: `workspaces.newPlacement`), `Int.max` last.
        guard let move = SidebarBridgeRules().groupCreateIndex(placed: place.move, requested: index) else { // no answer: no group, as before
            bridge.rows.edits.settle(token)
            return bridge.resync()
        }
        let top = place.topIndex, flow = self
        editor.creating[id] = []
        let settled: @MainActor () -> Void = { applied?(); bridge.rows.edits.settle(editor.removing.removeValue(forKey: id)) }
        life.commit("create-personal-group", ending: ending, recheck: { ending.filter(life.isEmptyUnpinned) }, failed: failed,
                    applied: settled, landed: { created in flow.landed(id, as: created) }) { connection -> WorkspaceGroupID in
            // The v2 operation names the group itself.
            let created = v2 ? WorkspaceGroupID(rawValue: try await connection.state.createWorkspaceGroup(
                name: SidebarGroup.named(name), room: room.rawValue, color: color.wire, index: move).id)
                : try await connection.createPersonalGroup(name: SidebarGroup.named(name), id: id, room: room, color: color.wire).id
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
        if editor.removing[local] != nil { ungroup(CmuxNextSidebar.GroupID(created.rawValue), .ungroup(CmuxNextSidebar.GroupID(created.rawValue))) }
    }

    /// `.ungroup` on the personal path, pending until the store has the delete (#26382): under the daemon's id for a group
    /// the sidebar made under its own (the sidebar's was refused), after its create (the local edit goes in `create`).
    func ungroup(_ group: CmuxNextSidebar.GroupID, _ intent: SidebarIntent) {
        let id = WorkspaceGroupID(rawValue: SidebarDocStore.personalGroupID(item: group.rawValue)), token = bridge.rows.edits.add(intent)
        if editor.creating[id] != nil { return bridge.rows.edits.settle(editor.removing.updateValue(token, forKey: id)) }
        let target = editor.created[id] ?? id, v2 = bridge.statePersonal
        bridge.rows.send("delete-personal-group", edit: token, on: bridge.services.machines.local, failed: bridge.saveFailed(intent)) {
            if v2 { return try await $0.state.deleteWorkspaceGroup(target.rawValue) }
            try await $0.deletePersonalGroup(target)
        }
    }

    /// `.renameGroup` / `.setGroupColor`. The editor opens on a new group at
    /// once, under the sidebar's own id: an edit before the daemon made the
    /// group waits for it, and later ones go to the daemon's id.
    func edit(_ group: CmuxNextSidebar.GroupID, name: String? = nil, color: GroupTint? = nil, _ intent: SidebarIntent) {
        // A pending edit until the store holds it, so a recompute (or the
        // pending new group's own edit) never shows the old name or color.
        let token = bridge.rows.edits.add(intent)
        let id = WorkspaceGroupID(rawValue: group.rawValue)
        if editor.creating[id] != nil {
            editor.creating[id]?.append(PersonalGroupEditorState.Edit(name: name, color: color, token: token))
            return
        }
        send(editor.created[id] ?? id, name: name, color: color, edit: token)
    }

    private func send(_ id: WorkspaceGroupID, name: String?, color: GroupTint?, edit: SidebarPendingEdits.Token) {
        let v2 = bridge.statePersonal, bridge = bridge, colorUpdate: FieldUpdate<String> = color.map { .set($0.wire) } ?? .unchanged, home = bridge.services.machines.local
        let group = CmuxNextSidebar.GroupID(id.rawValue)
        let intent: SidebarIntent = name.map { .renameGroup(group, $0) } ?? .setGroupColor(group, color ?? GroupTint.none)
        bridge.rows.send("update-personal-group", edit: edit, on: home, until: home.store.personal.writes.claim(group: id.rawValue, name == nil ? "color" : "name"),
                         failed: bridge.saveFailed(intent)) { connection in
            if v2 { return try await connection.state.updateWorkspaceGroup(id.rawValue, name: name, color: colorUpdate) }
            try await connection.updatePersonalGroup(id, name: name, color: colorUpdate)
        }
    }

    // MARK: The group editor's rows

    /// The editor's action rows run through the action registry with the
    /// group as their target, the same path as the palette, menus and CLI.
    func wireEditor() {
        let container = bridge.container
        container.groupEditorSurface = bridge.services.groupEditor
        container.groupEditorItems = { [weak bridge = self.bridge] group in
            bridge.map { SidebarGroupFlow(bridge: $0).editorItems(group) } ?? SidebarContainerView.standardGroupEditorItems()
        }
        container.onGroupEditorItem = { [weak bridge = self.bridge] group, item in
            if let bridge { SidebarGroupFlow(bridge: bridge).performEditorItem(group, item) }
        }
        container.groupSortMenu = { [weak bridge = self.bridge] in bridge?.services.registry.makeChoicesMenu(for: "workspaceGroup.setSort", in: .workspaceGroup, target: ActionTargetRef(kind: .workspaceGroup, id: $0.rawValue)) }
    }

    /// The standard rows with each action's current shortcut; the pin row reads as the change it makes.
    private func editorItems(_ group: CmuxNextSidebar.GroupID) -> [[SidebarGroupEditorItem]] {
        let registry = bridge.services.registry
        return SidebarContainerView.standardGroupEditorItems(pinned: bridge.model.group(group)?.isPinned ?? false) {
            registry.shortcutDisplay(for: ActionID(rawValue: $0))
        }
    }

    private func performEditorItem(_ group: CmuxNextSidebar.GroupID, _ item: String) {
        // Which rows keep a group made empty when the editor closes, and which run an action (`SidebarBridgeRules.editorItem`).
        // On the sidebar document a group from the personal store shows as its item (`itm_g_<id>`).
        let local = WorkspaceGroupID(rawValue: SidebarDocStore.personalGroupID(item: group.rawValue)), row = SidebarBridgeRules().editorItem(item)
        if row?.keepsGroup == true { editor.explicit.remove(local) }
        guard row?.performs == true else { return }
        // The daemon's id for a group the sidebar made under its own.
        let target = editor.created[local] ?? local
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .workspaceGroup, id: target.rawValue), origin: .user)
        _ = bridge.services.registry.perform(ActionID(rawValue: item), invocation: invocation)
    }
}
