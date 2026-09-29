import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSidebar

// Sidebar intents -> daemon commands, applied optimistically to the
// sidebar model first. Each command goes to the machine daemon that owns
// the workspace or group; workspaces never move between machines (a drop
// into another machine's section is refused and re-synced). The store
// mapping overwrites the model with daemon truth on the next change, so a
// rejected command reverts by itself; a rejection also forces one re-map.
extension SidebarBridge {
    func handle(_ intent: SidebarIntent) {
        switch intent {
        case .select(let id):
            model.apply(intent)
            services.windows.show(workspaceID: id.rawValue, in: state)
        case .reorder(let ids, let position):
            let before = model.sections
            model.apply(intent)
            reorder(ids, to: position, in: before)
        case .rename(let id, let name):
            model.apply(intent)
            guard let (workspace, daemon) = services.machines.workspace(id: id.rawValue), let key = workspace.key else { return }
            command("rename-workspace", on: daemon, patch: .renameWorkspace(key: key, name: name)) { c, _ in _ = try await c.renameWorkspace(key, to: name) }
        case .close(let ids):
            // The row's close button is an entrypoint of `closeWorkspace`,
            // so it asks the same confirmation and ends the terminals too.
            for id in ids {
                services.registry.perform("closeWorkspace", invocation: ActionInvocation(target: ActionTargetRef(kind: .workspace, id: id.rawValue)))
            }
        case .newWorkspace(let machine, _):
            let daemon = machine.flatMap { services.machines.daemon(machine: $0.rawValue) }
                ?? services.machines.daemon(machine: state.machineID)
            services.windows.newWorkspace(in: state, on: daemon)
        case .setColor(let ids, let color):
            model.apply(intent)
            for (daemon, key) in keys(ids) {
                let update: FieldUpdate<String> = color.map { .set($0.rawValue) } ?? .clear
                command("set-workspace-metadata", on: daemon) { c, _ in _ = try await c.setWorkspaceMetadata(key, color: update) }
            }
        case .toggleCollapse(let target):
            model.apply(intent)
            if case .group(let group) = target, let current = model.group(group), let daemon = daemon(ofGroup: group) {
                let id = WorkspaceGroupID(rawValue: group.rawValue), collapsed = current.isCollapsed
                command("update-workspace-group", on: daemon, patch: .setWorkspaceGroupCollapsed(id, collapsed: collapsed)) { c, _ in
                    _ = try await c.updateGroup(id, collapsed: collapsed)
                }
            }
        case .createGroup(let group, let name, let color, let ids):
            model.apply(intent)
            let id = WorkspaceGroupID(rawValue: group.rawValue)
            guard let (daemon, members) = sameMachine(ids) else { return resync() }
            command("create-workspace-group", on: daemon) { c, _ in
                _ = try await c.createGroup(name: name, id: id, color: color.rawValue)
                for key in members { _ = try await c.moveWorkspace(key, toGroup: id) }
            }
        case .move(let ids, let group):
            model.apply(intent)
            let id = WorkspaceGroupID(rawValue: group.rawValue)
            guard let target = daemon(ofGroup: group), let (daemon, members) = sameMachine(ids), daemon === target else { return resync() }
            for key in members { command("move-workspace-to-group", on: daemon) { c, _ in _ = try await c.moveWorkspace(key, toGroup: id) } }
        case .renameGroup(let group, let name):
            model.apply(intent)
            groupCommand("update-workspace-group", group) { c, id in _ = try await c.updateGroup(id, name: name) }
        case .setGroupColor(let group, let color):
            model.apply(intent)
            groupCommand("update-workspace-group", group) { c, id in _ = try await c.updateGroup(id, color: .set(color.rawValue)) }
        case .ungroup(let group):
            model.apply(intent)
            groupCommand("delete-workspace-group", group) { c, id in try await c.deleteGroup(id) }
        case .reorderGroup(let group, let index):
            model.apply(intent)
            groupCommand("move-workspace-group", group) { c, id in try await c.moveGroup(id, to: index) }
        case .closeGroup(let group):
            let members = (model.group(group)?.workspaces.map(\.id) ?? []).compactMap { id in
                services.machines.workspace(id: id.rawValue).flatMap { workspace, daemon in
                    workspace.key.map { (daemon, $0, WorkspaceClose.terminals(of: workspace, on: daemon)) }
                }
            }
            model.apply(intent)
            for (daemon, key, terminals) in members {
                command("close-workspace", on: daemon) { c, _ in try await WorkspaceClose.close(key, terminals: terminals, on: c) }
            }
        case .setIcon, .setPinned, .setGroupPinned, .openGroup:
            // Needs daemon fields this build does not map yet; apply locally
            // so the UI responds, the next store change restores truth.
            model.apply(intent)
        }
    }

    /// Each workspace's owning daemon and durable key, in order.
    private func keys(_ ids: [SidebarWorkspaceID]) -> [(DaemonService, WorkspaceKey)] {
        ids.compactMap { id in
            guard let (workspace, daemon) = services.machines.workspace(id: id.rawValue), let key = workspace.key else { return nil }
            return (daemon, key)
        }
    }

    /// The one daemon owning every workspace in `ids`, or nil when they span machines.
    private func sameMachine(_ ids: [SidebarWorkspaceID]) -> (DaemonService, [WorkspaceKey])? {
        let pairs = keys(ids)
        guard let daemon = pairs.first?.0, pairs.allSatisfy({ $0.0 === daemon }) else { return nil }
        return (daemon, pairs.map(\.1))
    }

    private func daemon(ofGroup group: GroupID) -> DaemonService? {
        let id = WorkspaceGroupID(rawValue: group.rawValue)
        return services.machines.daemons.first { $0.store.group(id) != nil }
    }

    private func groupCommand(_ label: String, _ group: GroupID,
                              _ body: @escaping @Sendable (DaemonConnection, WorkspaceGroupID) async throws -> Void) {
        guard let daemon = daemon(ofGroup: group) else { return }
        let id = WorkspaceGroupID(rawValue: group.rawValue)
        command(label, on: daemon) { c, _ in try await body(c, id) }
    }

    private func reorder(_ ids: [SidebarWorkspaceID], to position: DropPosition, in sections: [SidebarRowSection]) {
        guard case .machine(let machine) = position.section, let target = services.machines.daemon(machine: machine.rawValue),
              let (daemon, members) = sameMachine(ids), daemon === target,
              let root = WorkspaceOrdering.rootIndex(for: position, moving: ids, in: sections.filter { $0.id == position.section })
        else { return resync() }
        for (offset, key) in members.enumerated() {
            let index = root + offset
            if let group = position.group {
                let groupID = WorkspaceGroupID(rawValue: group.rawValue)
                command("move-workspace-to-group", on: daemon) { c, _ in _ = try await c.moveWorkspace(key, toGroup: groupID, index: index) }
            } else {
                command("move-workspace", on: daemon, patch: .moveWorkspace(key: key, index: index)) { c, _ in _ = try await c.moveWorkspace(key, to: index) }
            }
        }
    }

    /// Puts daemon truth back after a refused or rejected intent.
    private func resync() {
        model.sections = Self.sections(services.machines, statuses: services.statusBoard)
    }

    private func command(_ label: String, on daemon: DaemonService, patch: OptimisticPatch = .custom { _ in },
                         _ body: @escaping @Sendable (DaemonConnection, ClientTransactionID) async throws -> Void) {
        Task {
            if !(await daemon.perform(label, patch: patch, body)) { resync() }
        }
    }
}
