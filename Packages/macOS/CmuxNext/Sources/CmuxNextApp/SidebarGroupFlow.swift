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
    func newGroup(of ids: [SidebarWorkspaceID], name: String, byUser: Bool) {
        if byUser, name.isEmpty, bridge.usesPersonalOrganization, let whole = bridge.life.whole(bridge.placements(ids)) { return editGroup(whole) }
        bridge.handle(.createGroup(CmuxNextSidebar.GroupID.make(), name: name, color: .grey, workspaces: ids))
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
        let edit = bridge.pendingEdits.add(intent)
        bridge.showRows()
        life.commit("set-personal-workspace", ending: ending, recheck: { life.emptied(by: members, into: id) },
                    failed: { bridge.pendingEdits.settle(edit); bridge.resync() }, applied: { bridge.settle(edit) }) { connection in
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
        bridge.model.apply(intent)
        // Mixed order: the new group's place where the model formed it,
        // set before members join so it never shows at the end first.
        let place = bridge.usesMixedOrder && v2
            ? PersonalSidebarPlanner(machines: bridge.services.machines).groupPlacement(of: group, in: bridge.model.sections)
            : PersonalSidebar.GroupPlacement()
        let move = place.move, top = place.topIndex
        life.commit("create-personal-group", ending: ending, recheck: { life.emptied(by: members, into: nil) }, failed: { bridge.resync() }) { connection in
            // The v2 operation names the group itself.
            let created = v2 ? WorkspaceGroupID(rawValue: try await connection.state.createWorkspaceGroup(
                name: SidebarGroup.named(name), room: room.rawValue, color: color.rawValue, index: move).id)
                : try await connection.createPersonalGroup(name: SidebarGroup.named(name), id: id, room: room, color: color.rawValue).id
            try await PersonalGroupCreation.finish(created, topIndex: top, collapsed: collapsed, statePersonal: v2, on: connection)
            for workspace in members {
                try await connection.state.placePersonalWorkspace(session: workspace.session, key: workspace.key, resource: workspace.resource,
                                                                  group: .set(created))
            }
        }
    }
}
