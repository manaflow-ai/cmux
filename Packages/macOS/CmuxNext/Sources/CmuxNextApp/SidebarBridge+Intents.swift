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
        // A section's collapse is window view state (sidebar snapshot), never a daemon command.
        if case .toggleCollapse(.section) = intent {
            model.apply(intent)
            return recordSnapshot()
        }
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
        if usesPersonalOrganization, PersonalGroupPin(bridge: self).handle(intent) || handlePersonal(intent) { return }
        switch intent {
        case .select(let id):
            // A placeholder row is no workspace: never claimed or shown.
            guard !model.isPlaceholder(id) else { return }
            model.apply(intent)
            services.windows.show(workspaceID: id.rawValue, in: state)
        case let .selectTab(_, tab):
            _ = services.revealTab(tab.rawValue)
        case .moveTab:
            // Tab drags are committed by TabDragSession. Keep this intent
            // conservative until a sidebar-only tab move has a daemon
            // transaction path of its own.
            resync()
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
            // A machine turned off by policy (DisabledFeatures) gets nothing, not a local stand-in.
            if machine != nil || state.machineID != MachineRegistry.localID, daemon == nil { return }
            services.windows.newWorkspace(in: state, on: daemon, at: group.map(WorkspaceSlot.endOfGroup))
        case .setColor(let ids, let color):
            model.apply(intent)
            for (daemon, key) in keys(ids) {
                let update: FieldUpdate<String> = color.map { .set($0.rawValue) } ?? .clear
                let resource = daemon.store.stateResourceID(workspace: key)
                command("set-workspace-metadata", on: daemon) { c in try await c.state.setWorkspaceIdentity(key, resource: resource, color: update) }
            }
        case .toggleCollapse, .createGroup, .move, .renameGroup, .setGroupColor, .ungroup, .reorderGroup:
            // Workspace groups are personal (the home session's
            // `workspace_group.*`, `handlePersonal`); the shared group
            // commands are not used, so the daemon can drop them. Before personal state loads it waits.
            if !organizationQueue.hold(intent, local: services.machines.local) { refuseOrganization() }
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
            services.registry.perform("space.new", invocation: ActionInvocation())
        case .reorderProfile(let profile, let index):
            model.apply(intent)
            let id = ProfileID(rawValue: profile.rawValue)
            command("move-profile", on: services.machines.local) { c in try await c.moveProfile(id, to: index) }
        case .setPinned(let ids, let pinned):
            model.apply(intent)
            sendPinned(ids, pinned)
        case .activateItem(let id, let opensWorkspace):
            activateLayoutItem(id, opensWorkspace: opensWorkspace)
        case .installUpdate, .setAutomaticUpdates, .openUpdateLink, .tryTip, .dismissTip:
            SidebarCardFeed.handle(intent, services: services)
        case .layout(let op):
            applyLayoutOp(op)
        case .dropOnLayoutSection(let ids, let section, let index):
            PinCommands(context: AppActionContext(services: services)).userDrop(ids.map(\.rawValue), on: section, at: index)
        case .toggleLayoutSection:
            model.apply(intent)
        case .groupEditorEnded:
            // Only a personal group made empty has an end rule (handlePersonal).
            break
        case .setIcon, .setGroupPinned, .setGroupIcon, .openGroup:
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

    func reorder(_ ids: [SidebarWorkspaceID], to position: DropPosition, in sections: [SidebarRowSection]) {
        guard case .machine(let machine) = position.section, let target = services.machines.daemon(machine: machine.rawValue),
              let (daemon, _) = sameMachine(ids), daemon === target
        else { return resync() }
        // Groups are personal: the machine's own order is one flat list.
        let entries = daemon.store.workspaces.map { WorkspaceMovePlan.Entry(id: $0.id, group: nil) }
        guard let commands = WorkspaceMovePlan.commands(for: position, moving: ids, window: sections, daemon: entries, groups: false)
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
                case .place:
                    // Never planned without groups (`groups: false`).
                    ok = false
                }
                if !ok {
                    resync()
                    return
                }
            }
        }
    }

    /// Refuses an organization intent that personal state cannot take.
    func refuseOrganization() {
        services.registry.refuse(services.machines.local.personalStateUnavailableReason)
        resync()
    }

    /// Puts daemon truth back after a refused or rejected intent.
    func resync() {
        guard let state else { return }
        model.ungroupedFirst = !usesMixedOrder
        model.setSections(Self.sections(services.machines, members: services.windows.registry.members(of: state.id), profile: state.profileID,
                                        hidesHome: Self.hidesHome(services.sidebarLayout.document), selection: state.selection,
                                        newTabPages: services.agentTabs.pageTabs.ids, muted: services.notifications.preferences.mutedWorkspaces))
        model.profiles = Self.profiles(services.machines.local.store)
        openPendingGroupEditor()
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
