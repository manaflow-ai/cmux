import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSidebar

// Sidebar organization intents when the home session serves personal state
// (plans/cmux-next/data-model.md 1.2c): groups, group membership and order
// are personal rows in the home daemon, keyed by qualified workspace, and
// are never written to the daemon that owns the workspace. Each intent is
// applied to the sidebar model first (optimistic); the next personal
// snapshot overwrites it with daemon truth, and a rejection re-syncs.
extension SidebarBridge {
    var usesPersonalOrganization: Bool { services.machines.local.store.personal.isLoaded }
    /// The home session places groups among the loose workspaces (`personal-mixed-order-v1`).
    var usesMixedOrder: Bool { services.machines.local.store.supportsPersonalMixedOrder }

    /// Handles an organization intent in personal mode. Returns false for
    /// intents that are not about organization.
    func handlePersonal(_ intent: SidebarIntent) -> Bool {
        guard let state else { return false }
        switch intent {
        case .reorder(let ids, let position):
            let before = model.sections
            model.apply(intent)
            placePersonal(ids, at: position, in: before)
        case .move(let ids, let group):
            let id = WorkspaceGroupID(rawValue: group.rawValue), members = placements(ids)
            // The groups these workspaces leave empty go too (cx-rcby).
            let ending = life.emptied(by: members, into: id)
            model.apply(intent)
            life.commit("set-personal-workspace", ending: ending, failed: resync, settled: holdRows()) { connection in
                for workspace in members {
                    try await connection.state.placePersonalWorkspace(session: workspace.session, key: workspace.key, resource: workspace.resource,
                                                                      group: .set(id))
                }
            }
        case .createGroup(let group, let name, let color, let ids, _, let collapsed):
            let id = WorkspaceGroupID(rawValue: group.rawValue), room = state.profileID, members = placements(ids), v2 = statePersonal
            let ending = life.emptied(by: members, into: nil)
            model.apply(intent)
            // Mixed order: the new group's place where the model formed it,
            // set before members join so it never shows at the end first.
            let place = usesMixedOrder && v2 ? PersonalSidebarPlanner(machines: services.machines).groupPlacement(of: group, in: model.sections)
                : PersonalSidebar.GroupPlacement()
            let move = place.move, top = place.topIndex
            life.commit("create-personal-group", ending: ending, failed: resync, settled: holdRows()) { connection in
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
        case .groupEditorEnded(let group):
            // A group made with no member goes when its editor closes empty.
            let id = WorkspaceGroupID(rawValue: group.rawValue)
            guard groupEditor.explicit.remove(id) != nil else { return true }
            life.deleteIfEmpty(id, failed: resync)
        case .renameGroup(let group, let name):
            model.apply(intent)
            let v2 = statePersonal
            personal("update-personal-group") {
                if v2 { return try await $0.state.updateWorkspaceGroup(group.rawValue, name: name) }
                try await $0.updatePersonalGroup(WorkspaceGroupID(rawValue: group.rawValue), name: name)
            }
        case .setGroupColor(let group, let color):
            model.apply(intent)
            let v2 = statePersonal
            personal("update-personal-group") {
                if v2 { return try await $0.state.updateWorkspaceGroup(group.rawValue, color: .set(color.rawValue)) }
                try await $0.updatePersonalGroup(WorkspaceGroupID(rawValue: group.rawValue), color: .set(color.rawValue))
            }
        case .toggleCollapse(.group(let group)):
            model.apply(intent)
            guard let collapsed = model.group(group)?.isCollapsed else { return true }
            let v2 = statePersonal
            personal("update-personal-group") {
                if v2 { return try await $0.state.updateWorkspaceGroup(group.rawValue, collapsed: collapsed) }
                try await $0.updatePersonalGroup(WorkspaceGroupID(rawValue: group.rawValue), collapsed: collapsed)
            }
        case .ungroup(let group):
            model.apply(intent)
            let v2 = statePersonal
            personal("delete-personal-group") {
                if v2 { return try await $0.state.deleteWorkspaceGroup(group.rawValue) }
                try await $0.deletePersonalGroup(WorkspaceGroupID(rawValue: group.rawValue))
            }
        case .reorderGroup(let group, _):
            model.apply(intent)
            // The intent's index counts section nodes; the daemon wants a
            // group-order index (and, mixed, the group's place among the rows).
            let place = PersonalSidebarPlanner(machines: services.machines).groupPlacement(of: group, in: model.sections)
            let v2 = statePersonal, move = place.move, top = place.topIndex
            personal("move-personal-group") { connection in
                if let move {
                    if v2 {
                        try await connection.state.moveWorkspaceGroup(group.rawValue, to: move)
                    } else {
                        try await connection.movePersonalGroup(WorkspaceGroupID(rawValue: group.rawValue), to: move)
                    }
                }
                if v2, top != .unchanged { try await connection.state.updateWorkspaceGroup(group.rawValue, topIndex: top) }
            }
        default:
            return false
        }
        return true
    }

    /// Personal order and group for `ids` at `position` in this window's
    /// `sections` (taken before the move): one `set-personal-workspace`
    /// each in the home session; the workspace's own daemon is not written.
    func placePersonal(_ ids: [SidebarWorkspaceID], at position: DropPosition, in sections: [SidebarRowSection]) {
        let group = position.group.map { WorkspaceGroupID(rawValue: $0.rawValue) }
        guard let plan = PersonalSidebarPlanner(machines: services.machines).dropPlan(ids, at: position, in: sections) else { return resync() }
        let regroup = statePersonal ? plan.regroup : []
        // Only the dropped workspaces leave their group; a group they empty goes (cx-rcby).
        let ending = life.emptied(by: plan.steps.filter(\.moves).map(\.workspace), into: group)
        life.commit("set-personal-workspace", ending: ending, failed: resync, settled: holdRows()) { connection in
            for step in plan.steps {
                try await connection.state.placePersonalWorkspace(session: step.workspace.session, key: step.workspace.key,
                                                                  resource: step.workspace.resource,
                                                                  group: step.moves ? (group.map { .set($0) } ?? .clear) : .unchanged,
                                                                  index: step.index)
            }
            guard let first = plan.first else { return }
            for id in regroup { try await connection.state.updateWorkspaceGroup(id.rawValue, topIndex: .set(first)) }
        }
    }

    /// The group lifecycle rule (cx-rcby).
    var life: PersonalGroupLife { PersonalGroupLife(machines: services.machines) }

    /// Keeps the sidebar's optimistic rows until an organization change's
    /// commands have all landed, then shows daemon truth once (cx-rcby): a
    /// new group's create, place and delete commits each send a snapshot,
    /// and showing them one by one made the group jump (it arrived empty,
    /// its member snapped back, then moved in). Returns the release.
    func holdRows() -> @MainActor () -> Void {
        groupEditor.rowHolds += 1
        return { [weak self] in
            guard let self else { return }
            groupEditor.rowHolds -= 1
            if groupEditor.rowHolds == 0 { resync() }
        }
    }

    /// A new group with no member, its name editor open; it goes when the
    /// editor closes while it is still empty (`groupEditorEnded`).
    func newEmptyGroup(name: String) {
        guard let state else { return }
        let room = state.profileID, v2 = statePersonal, home = services.machines.local, id = WorkspaceGroupID(rawValue: CmuxNextSidebar.GroupID.make().rawValue)
        // The first palette color no group uses yet (never blue or grey, GroupColor.automatic).
        let color = GroupColor.automatic(used: Set(home.store.personal.groups.compactMap(\.color))) ?? .grey
        Task { [weak self] in
            let created = await home.request("create-personal-group") { connection -> WorkspaceGroupID in
                v2 ? WorkspaceGroupID(rawValue: try await connection.state.createWorkspaceGroup(
                    name: SidebarGroup.named(name), room: room.rawValue, color: color.rawValue).id)
                    : try await connection.createPersonalGroup(name: SidebarGroup.named(name), id: id, room: room, color: color.rawValue).id
            }
            guard let self else { return }
            guard let created else { return resync() }
            groupEditor.explicit.insert(created)
            editGroup(created)
        }
    }

    /// Opens `group`'s name editor now, or once the sidebar shows it.
    func editGroup(_ group: WorkspaceGroupID) {
        groupEditor.pending = group
        openPendingGroupEditor()
    }

    /// Called after each sidebar update: opens a waiting group editor.
    func openPendingGroupEditor() {
        guard let pending = groupEditor.pending, model.group(CmuxNextSidebar.GroupID(pending.rawValue)) != nil else { return }
        groupEditor.pending = nil
        container.beginRename(group: CmuxNextSidebar.GroupID(pending.rawValue))
    }

    /// The home session serves its personal groups as v2 state resources
    /// (`workspace_group.*`, `workspace.place`).
    var statePersonal: Bool { services.machines.local.store.servesStateResources }

    func placements(_ ids: [SidebarWorkspaceID]) -> [PersonalSidebarPlanner.Placement] {
        PersonalSidebarPlanner(machines: services.machines).placements(ids)
    }

    /// Sends one personal-state command to the home daemon; a failure
    /// re-syncs the sidebar.
    private func personal(_ label: String, _ body: @escaping @Sendable (DaemonConnection) async throws -> Void) {
        let home = services.machines.local
        Task {
            if await home.request(label, body) == nil { resync() }
        }
    }
}
