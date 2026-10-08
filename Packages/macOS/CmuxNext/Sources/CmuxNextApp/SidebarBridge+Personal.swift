import CmuxNextBridge
import CmuxNextDaemon
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
            model.apply(intent)
            let id = WorkspaceGroupID(rawValue: group.rawValue)
            for workspace in placements(ids) {
                personal("set-personal-workspace") {
                    try await $0.state.placePersonalWorkspace(session: workspace.session, key: workspace.key, resource: workspace.resource,
                                                        group: .set(id))
                }
            }
        case .createGroup(let group, let name, let color, let ids, _, let collapsed):
            model.apply(intent)
            let id = WorkspaceGroupID(rawValue: group.rawValue), room = state.profileID, members = placements(ids), v2 = statePersonal
            // Mixed order: the new group's place where the model formed it,
            // set before members join so it never shows at the end first.
            let place = usesMixedOrder && v2 ? PersonalSidebarPlanner(machines: services.machines).groupPlacement(of: group, in: model.sections)
                : PersonalSidebar.GroupPlacement()
            let move = place.move, top = place.topIndex
            personal("create-personal-group") { connection in
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
        personal("set-personal-workspace") { connection in
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
