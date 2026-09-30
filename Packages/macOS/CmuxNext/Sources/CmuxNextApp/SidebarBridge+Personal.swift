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
            for workspace in qualified(ids) {
                personal("set-personal-workspace") {
                    try await $0.setPersonalWorkspace(SetPersonalWorkspaceRequest(
                        sessionID: workspace.session, workspaceKey: WorkspaceKey(rawValue: workspace.key), group: .set(id)))
                }
            }
        case .createGroup(let group, let name, let color, let ids):
            model.apply(intent)
            let id = WorkspaceGroupID(rawValue: group.rawValue), room = state.profileID, members = qualified(ids)
            personal("create-personal-group") { connection in
                _ = try await connection.createPersonalGroup(name: name, id: id, room: room, color: color.rawValue)
                for workspace in members {
                    try await connection.setPersonalWorkspace(SetPersonalWorkspaceRequest(
                        sessionID: workspace.session, workspaceKey: WorkspaceKey(rawValue: workspace.key), group: .set(id)))
                }
            }
        case .renameGroup(let group, let name):
            model.apply(intent)
            personal("update-personal-group") { try await $0.updatePersonalGroup(WorkspaceGroupID(rawValue: group.rawValue), name: name) }
        case .setGroupColor(let group, let color):
            model.apply(intent)
            personal("update-personal-group") {
                try await $0.updatePersonalGroup(WorkspaceGroupID(rawValue: group.rawValue), color: .set(color.rawValue))
            }
        case .toggleCollapse(.group(let group)):
            model.apply(intent)
            guard let collapsed = model.group(group)?.isCollapsed else { return true }
            personal("update-personal-group") {
                try await $0.updatePersonalGroup(WorkspaceGroupID(rawValue: group.rawValue), collapsed: collapsed)
            }
        case .ungroup(let group):
            model.apply(intent)
            personal("delete-personal-group") { try await $0.deletePersonalGroup(WorkspaceGroupID(rawValue: group.rawValue)) }
        case .reorderGroup(let group, let index):
            model.apply(intent)
            personal("move-personal-group") { try await $0.movePersonalGroup(WorkspaceGroupID(rawValue: group.rawValue), to: index) }
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
        guard let index = personalIndex(for: position, moving: ids, in: sections) else { return resync() }
        for (offset, workspace) in qualified(ids).enumerated() {
            personal("set-personal-workspace") {
                try await $0.setPersonalWorkspace(SetPersonalWorkspaceRequest(
                    sessionID: workspace.session, workspaceKey: WorkspaceKey(rawValue: workspace.key), index: index + offset,
                    group: group.map { .set($0) } ?? .clear))
            }
        }
    }

    /// The sidebar ids as workspaces qualified by their session, in order.
    func qualified(_ ids: [SidebarWorkspaceID]) -> [RoomMembership.Workspace] {
        ids.compactMap { WindowProfiles.qualified($0.rawValue, machines: services.machines) }
    }

    /// The personal insertion index for a drop at `position` in this
    /// window's `sections`: before the workspace at that slot in the full
    /// personal order, else after this window's last one.
    private func personalIndex(for position: DropPosition, moving ids: [SidebarWorkspaceID], in sections: [SidebarRowSection]) -> Int? {
        let scoped = sections.filter { $0.id == position.section }
        guard let local = WorkspaceOrdering.rootIndex(for: position, moving: ids, in: scoped) else { return nil }
        let moved = Set(qualified(ids).map { "\($0.session)/\($0.key)" })
        let key = { (id: String) in WindowProfiles.qualified(id, machines: self.services.machines).map { "\($0.session)/\($0.key)" } }
        let localOrder = scoped.flatMap(\.workspaces).compactMap { key($0.id.rawValue) }.filter { !moved.contains($0) }
        let global = PersonalSidebar.globalOrder(services.machines.local.store.personal).filter { !moved.contains($0) }
        return SidebarMembership.globalIndex(localIndex: local, local: localOrder, global: global)
    }

    /// Sends one personal-state command to the home daemon; a failure
    /// re-syncs the sidebar.
    private func personal(_ label: String, _ body: @escaping @Sendable (DaemonConnection) async throws -> Void) {
        let home = services.machines.local
        Task {
            if !(await home.perform(label, patch: .custom { _ in }) { connection, _ in try await body(connection) }) { resync() }
        }
    }
}
