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
            groupFlow.move(ids, into: group, intent)
        case .createGroup(let group, let name, let color, let ids, _, let collapsed):
            groupFlow.create(group, name: name, color: color, ids, collapsed: collapsed, room: state.profileID, intent)
        case .groupEditorEnded(let group):
            groupFlow.editorEnded(WorkspaceGroupID(rawValue: group.rawValue))
        case .renameGroup(let group, let name):
            groupFlow.edit(group, name: name, intent)
        case .setGroupColor(let group, let color):
            groupFlow.edit(group, color: color, intent)
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
        let moving = plan.steps.filter(\.moves).map(\.workspace), life = self.life
        let ending = life.emptied(by: moving, into: group)
        life.commit("set-personal-workspace", ending: ending, recheck: { life.emptied(by: moving, into: group) }, failed: resync) { connection in
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

    /// The group lifecycle rule and new groups (cx-rcby).
    var life: PersonalGroupLife { PersonalGroupLife(machines: services.machines) }
    var groupFlow: SidebarGroupFlow { SidebarGroupFlow(bridge: self) }

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
