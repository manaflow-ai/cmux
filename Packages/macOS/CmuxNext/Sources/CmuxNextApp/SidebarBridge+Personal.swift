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
        case .createGroup(let group, let name, let color, let ids):
            model.apply(intent)
            let id = WorkspaceGroupID(rawValue: group.rawValue), room = state.profileID, members = placements(ids), v2 = statePersonal
            personal("create-personal-group") { connection in
                // The v2 operation names the group itself.
                let created = v2 ? WorkspaceGroupID(rawValue: try await connection.state.createWorkspaceGroup(
                    name: name, room: room.rawValue, color: color.rawValue).id)
                    : try await connection.createPersonalGroup(name: name, id: id, room: room, color: color.rawValue).id
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
        case .reorderGroup(let group, let index):
            model.apply(intent)
            let v2 = statePersonal
            personal("move-personal-group") {
                if v2 { return try await $0.state.moveWorkspaceGroup(group.rawValue, to: index) }
                try await $0.movePersonalGroup(WorkspaceGroupID(rawValue: group.rawValue), to: index)
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
        let scoped = sections.filter { $0.id == position.section }
        guard let local = WorkspaceOrdering.shared.rootIndex(for: position, moving: ids, in: scoped) else { return resync() }
        // Each sidebar workspace as `session/key`, the personal order's key.
        var byKey: [String: PersonalPlacement] = [:]
        let key = { (id: SidebarWorkspaceID) -> String? in
            guard let placement = self.placements([id]).first else { return nil }
            let qualified = "\(placement.session)/\(placement.key.rawValue)"
            byKey[qualified] = placement
            return qualified
        }
        let moving = ids.compactMap(key)
        let moved = Set(moving)
        let shown = scoped.flatMap(\.workspaces).compactMap { key($0.id) }.filter { !moved.contains($0) }
        let rowed = PersonalSidebar.globalOrder(services.machines.local.store.personal).filter { !moved.contains($0) }
        let plan = SidebarMembership.personalPlacements(moving: moving, localIndex: local, shown: shown, rowed: rowed)
        // One task, in order: each index assumes the previous placement applied.
        let steps = plan.compactMap { step in byKey[step.key].map { (workspace: $0, index: step.index, moves: moved.contains(step.key)) } }
        personal("set-personal-workspace") { connection in
            for step in steps {
                // Only the moved workspaces change group; the others keep theirs.
                try await connection.state.placePersonalWorkspace(session: step.workspace.session, key: step.workspace.key,
                                                                  resource: step.workspace.resource,
                                                                  group: step.moves ? (group.map { .set($0) } ?? .clear) : .unchanged,
                                                                  index: step.index)
            }
        }
    }

    /// The home session serves its personal groups as v2 state resources
    /// (`workspace_group.*`, `workspace.place`).
    var statePersonal: Bool { services.machines.local.store.servesStateResources }

    /// One sidebar workspace as the home session places it: its session and
    /// key, and its public id when the home daemon owns it and takes
    /// `workspace.place` (other sessions' workspaces keep the raw command).
    struct PersonalPlacement: Sendable {
        var session: String
        var key: WorkspaceKey
        var resource: ResourceID?
    }

    func placements(_ ids: [SidebarWorkspaceID]) -> [PersonalPlacement] {
        let home = services.machines.local.store
        return qualified(ids).map { workspace in
            let key = WorkspaceKey(rawValue: workspace.key)
            return PersonalPlacement(session: workspace.session, key: key, resource: home.personalStateID(session: workspace.session, key: key))
        }
    }

    /// The sidebar ids as workspaces qualified by their session, in order.
    func qualified(_ ids: [SidebarWorkspaceID]) -> [RoomMembership.Workspace] {
        ids.compactMap { WindowProfiles.qualified($0.rawValue, machines: services.machines) }
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
