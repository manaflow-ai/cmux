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
        guard let state else { return }
        // The Pinned section is the daemon's pin, in either organization: a
        // drop there pins, a pinned workspace dropped on its own machine
        // unpins. Pinned order follows the sidebar, so a drop of workspaces
        // that are all pinned already only snaps back.
        if case .reorder(let ids, let position) = intent {
            switch position.section {
            case .pinned:
                let unpinned = ids.filter { services.machines.workspace(id: $0.rawValue)?.0.pinned != true }
                guard !unpinned.isEmpty else { return resync() }
                model.apply(intent)
                return sendPinned(unpinned, true)
            case .machine(let machine):
                let target = services.machines.daemon(machine: machine.rawValue)
                let leaving = ids.filter { id in
                    guard let (workspace, daemon) = services.machines.workspace(id: id.rawValue) else { return false }
                    return workspace.pinned && daemon === target
                }
                if !leaving.isEmpty { sendPinned(leaving, false) }
            }
        }
        if usesPersonalOrganization, handlePersonal(intent) { return }
        switch intent {
        case .select(let id):
            model.apply(intent)
            services.windows.show(workspaceID: id.rawValue, in: state)
        case .selectHome:
            model.apply(intent)
            HomeNavigation.show(in: state, windows: services.windows)
        case .reorder(let ids, let position):
            let before = model.sections
            model.apply(intent)
            reorder(ids, to: position, in: before)
        case .rename(let id, let name):
            model.apply(intent)
            guard let (workspace, daemon) = services.machines.workspace(id: id.rawValue), let key = workspace.key else { return }
            command("rename-workspace", on: daemon, intent: .renameWorkspace(key: key, name: name)) { c in _ = try await c.renameWorkspace(key, to: name) }
        case .close(let ids):
            // The row's close button is an entrypoint of `closeWorkspace`,
            // so it asks the same confirmation and ends the terminals too.
            for id in ids {
                services.registry.perform("closeWorkspace", invocation: ActionInvocation(target: ActionTargetRef(kind: .workspace, id: id.rawValue)))
            }
        case .newWorkspace(let machine, let group):
            // A double-click in a group's empty part, or its "+": the end of that group.
            let daemon = machine.flatMap { services.machines.daemon(machine: $0.rawValue) }
                ?? services.machines.daemon(machine: state.machineID)
            services.windows.newWorkspace(in: state, on: daemon, at: group.map(WorkspaceSlot.endOfGroup))
        case .setColor(let ids, let color):
            model.apply(intent)
            for (daemon, key) in keys(ids) {
                let update: FieldUpdate<String> = color.map { .set($0.rawValue) } ?? .clear
                command("set-workspace-metadata", on: daemon) { c in _ = try await c.setWorkspaceMetadata(key, color: update) }
            }
        case .toggleCollapse(let target):
            model.apply(intent)
            if case .group(let group) = target, let current = model.group(group), let daemon = daemon(ofGroup: group) {
                let id = WorkspaceGroupID(rawValue: group.rawValue), collapsed = current.isCollapsed
                command("update-workspace-group", on: daemon, intent: .setWorkspaceGroupCollapsed(id, collapsed: collapsed)) { c in
                    _ = try await c.updateGroup(id, collapsed: collapsed)
                }
            }
        case .createGroup(let group, let name, let color, let ids):
            model.apply(intent)
            let id = WorkspaceGroupID(rawValue: group.rawValue)
            guard let (daemon, members) = sameMachine(ids) else { return resync() }
            command("create-workspace-group", on: daemon) { c in
                _ = try await c.createGroup(name: name, id: id, color: color.rawValue)
                for key in members { _ = try await c.moveWorkspace(key, toGroup: id) }
            }
        case .move(let ids, let group):
            model.apply(intent)
            guard let target = daemon(ofGroup: group), let (daemon, _) = sameMachine(ids), daemon === target else { return resync() }
            // Appended in order, like the sidebar: each lands after the group's last member.
            let end = daemon.store.workspaces.count { $0.group?.rawValue == group.rawValue && !ids.contains(SidebarWorkspaceID($0.id)) }
            run(ids.enumerated().map { .place(id: $1.rawValue, group: group.rawValue, index: end + $0) }, on: daemon)
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
                    workspace.key.map { (daemon, $0, WorkspaceClose.closing(workspace, on: daemon)) }
                }
            }
            model.apply(intent)
            for (daemon, key, terminals) in members {
                command("close-workspace", on: daemon) { c in try await WorkspaceClose.close(key, terminals: terminals, on: c) }
            }
        case .switchProfile(let profile):
            services.windows.switchProfile(ProfileID(rawValue: profile.rawValue), in: state)
        case .newProfile:
            services.registry.perform("room.new", invocation: ActionInvocation())
        case .reorderProfile(let profile, let index):
            model.apply(intent)
            let id = ProfileID(rawValue: profile.rawValue)
            command("move-profile", on: services.machines.local) { c in try await c.moveProfile(id, to: index) }
        case .setPinned(let ids, let pinned):
            model.apply(intent)
            sendPinned(ids, pinned)
        case .activateItem(let id):
            activateLayoutItem(id)
        case .layout(let op):
            applyLayoutOp(op)
        case .toggleLayoutSection:
            model.apply(intent)
        case .setIcon, .setGroupPinned, .openGroup:
            // Needs daemon fields this build does not map yet; apply locally
            // so the UI responds, the next store change restores truth.
            model.apply(intent)
        }
    }

    /// `set-workspace-metadata` with the pin, per owning daemon. A daemon
    /// without `workspace-pin-v1` keeps the row where it was.
    private func sendPinned(_ ids: [SidebarWorkspaceID], _ pinned: Bool) {
        for (daemon, key) in keys(ids) {
            guard daemon.supports(DaemonCapabilities.shared.workspacePin) else {
                resync()
                continue
            }
            command("set-workspace-metadata", on: daemon) { c in _ = try await c.setWorkspaceMetadata(key, pinned: pinned) }
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
    func sameMachine(_ ids: [SidebarWorkspaceID]) -> (DaemonService, [WorkspaceKey])? {
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
        command(label, on: daemon) { c in try await body(c, id) }
    }

    func reorder(_ ids: [SidebarWorkspaceID], to position: DropPosition, in sections: [SidebarRowSection]) {
        guard case .machine(let machine) = position.section, let target = services.machines.daemon(machine: machine.rawValue),
              let (daemon, _) = sameMachine(ids), daemon === target
        else { return resync() }
        let store = daemon.store
        let entries = store.workspaces.map { WorkspaceMovePlan.Entry(id: $0.id, group: $0.group?.rawValue) }
        let groups = daemon.supports(DaemonCapabilities.shared.workspaceGroups)
        guard let commands = WorkspaceMovePlan.commands(for: position, moving: ids, window: sections, daemon: entries, groups: groups)
        else { return resync() }
        run(commands, on: daemon)
    }

    /// Sends reorder commands one after another in one task: each index
    /// assumes the previous command applied. A rejection re-syncs.
    private func run(_ commands: [WorkspaceMovePlan.Command], on daemon: DaemonService) {
        let keys = Dictionary(daemon.store.workspaces.compactMap { model in model.key.map { (model.id, $0) } },
                              uniquingKeysWith: { first, _ in first })
        Task {
            for command in commands {
                let ok: Bool
                switch command {
                case .move(let id, let index):
                    guard let key = keys[id] else { continue }
                    ok = await daemon.intend("move-workspace", .moveWorkspace(key: key, index: index)) { c in
                        _ = try await c.moveWorkspace(key, to: index)
                    }
                case .place(let id, let group, let index):
                    guard let key = keys[id] else { continue }
                    let groupID = group.map(WorkspaceGroupID.init(rawValue:))
                    ok = await daemon.intend("move-workspace-to-group", .placeWorkspace(key: key, group: groupID, index: index)) { c in
                        _ = try await c.moveWorkspace(key, toGroup: groupID, index: index)
                    }
                }
                if !ok {
                    resync()
                    return
                }
            }
        }
    }

    /// Puts daemon truth back after a refused or rejected intent.
    func resync() {
        guard let state else { return }
        model.sections = Self.sections(services.machines, statuses: services.statusBoard,
                                       members: services.windows.registry.members(of: state.id), profile: state.profileID)
        model.profiles = Self.profiles(services.machines.local.store)
    }

    /// Sends one command, shown at once through the store's intent log when
    /// it has an `intent`; a failure re-syncs the sidebar.
    private func command(_ label: String, on daemon: DaemonService, intent: Intent? = nil,
                         _ body: @escaping @Sendable (DaemonConnection) async throws -> Void) {
        Task {
            let ok = if let intent { await daemon.intend(label, intent, body) } else { await daemon.request(label, body) != nil }
            if !ok { resync() }
        }
    }
}
