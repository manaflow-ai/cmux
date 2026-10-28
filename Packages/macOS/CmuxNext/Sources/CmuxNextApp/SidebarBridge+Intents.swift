import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSettings
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
        // A group's fold is view state: this window shows it now, on that group's rows only, then tells the
        // document (its owner of record) the value. No round trip and no rebuild (state-ownership-DESIGN.md).
        if case let .toggleCollapse(.group(group)) = intent, SidebarDocWiring.isActive, let doc = SidebarDocStore.current,
           let shown = model.group(group)?.isCollapsed {
            rows.foldShown(group, collapsed: !shown)
            doc.setGroupCollapsed(group.rawValue, !shown) { [weak self] in self?.rows.dropFold(group) }
            return
        }
        if CloudCreationRows.handle(intent, bridge: self, state: state) || SidebarDocWiring.handle(intent, bridge: self) { return }
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
            case .pinned, .custom: // a custom section lists only on the sidebar document, which took the intent above
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
            // A pick in this window's sidebar shows here, also a workspace another window lists.
            services.windows.show(workspaceID: id.rawValue, in: state, from: .thisWindow)
        case let .selectTab(_, tab):
            _ = services.revealTab(tab.rawValue)
        case let .closeTab(_, tab):
            // A middle-click on a listed tab: Close Tab on that tab alone (an explicit target is never widened to the
            // strip's selection), the tab strip's middle-click path, so Reopen Closed (Cmd-Shift-T) brings it back.
            _ = services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.rawValue), origin: .user))
        case .moveTab:
            // Tab drags are committed by TabDragSession. Keep this intent
            // conservative until a sidebar-only tab move has a daemon
            // transaction path of its own.
            resync()
        case .reorder(let ids, let position):
            // A pending edit, as on the personal path: each command's echo shows no step between.
            SidebarDaemonReorder.reorder(ids, to: position, in: model.sections, edit: rows.add(intent), bridge: self)
        case .rename(let id, let name):
            model.apply(intent)
            guard let (workspace, daemon) = services.machines.workspace(id: id.rawValue), let key = workspace.key else { return }
            command("rename-workspace", on: daemon, intent: .renameWorkspace(key: key, name: name)) { c in _ = try await c.renameWorkspace(key, to: name) }
        case .close(let ids):
            // The row's close button is an entrypoint of `closeWorkspace`,
            // so it asks the same confirmation and ends the terminals too.
            // Several selected rows (Cmd-W, the row menu's Close, Delete) close as one batch.
            if ids.count > 1 { return WorkspaceSelectionClose.close(ids.map(\.rawValue), in: state, services) }
            for id in ids { services.registry.perform("closeWorkspace", invocation: ActionInvocation(closingRow: id.rawValue)) }
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
                // A store intent (#25657): the color stays through every live recompute until the reply settles it,
                // and a refusal takes it back; without it the next recompute showed the old color until the echo.
                command("set-workspace-metadata", on: daemon, intent: .setWorkspaceColor(key: key, color: color?.rawValue)) { c in try await c.state.setWorkspaceIdentity(key, resource: resource, color: update) }
            }
        case .toggleCollapse, .createGroup, .move, .renameGroup, .setGroupColor, .ungroup, .reorderGroup:
            // Workspace groups are personal (the home session's
            // `workspace_group.*`, `handlePersonal`); the shared group
            // commands are not used, so the daemon can drop them. Before personal state loads it waits.
            if !organizationQueue.hold(intent, local: services.machines.local) { refuseOrganization() }
        case .closeGroup(let group):
            let members = (model.group(group)?.workspaces ?? []).compactMap { services.machines.workspace(id: $0.id.rawValue) }
            model.apply(intent)
            // One gesture, one closed group per daemon: one Reopen Closed brings the group's workspaces back.
            WorkspaceClose.close(members) { daemon, label, body in command(label, on: daemon, body) }
        case .switchProfile(let profile):
            services.windows.switchProfile(ProfileID(rawValue: profile.rawValue), in: state)
        case .newProfile:
            services.registry.perform("space.new", invocation: ActionInvocation())
        case .openProfileInNewWindow(let profile):
            let invocation = ActionInvocation(target: ActionTargetRef(kind: .profile, id: profile.rawValue), origin: .user)
            services.registry.perform("space.openInNewWindow", invocation: invocation)
        case .reorderProfile(let profile, let index):
            model.apply(intent)
            let id = ProfileID(rawValue: profile.rawValue)
            command("move-profile", on: services.machines.local) { c in try await c.moveProfile(id, to: index) }
        case .setPinned(let ids, let pinned):
            model.apply(intent)
            sendPinned(ids, pinned)
        case .activateItem(let id, let opensWorkspace):
            activateLayoutItem(id, opensWorkspace: opensWorkspace)
        case .installUpdate, .downloadUpdate, .setAutomaticUpdates, .openUpdateLink, .openUpdateChanges, .noticeAction, .dismissNotice, .openWhatsNew, .dismissUpdated,
             .hideNowPlayingCard, .addItems:
            SidebarCardFeed.handle(intent, services: services)
        case .nowPlaying(let command): services.cache.pageRequests.sidebarSources.perform(command)
        case .toggleWorkspaceAudio(let id):
            // The row's speaker runs the workspace menu's, palette's and CLI's action, on its row alone.
            var invocation = ActionInvocation(target: ActionTargetRef(kind: .workspace, id: id.rawValue), origin: .user)
            invocation.closesRowOnly = true
            _ = services.registry.perform(BrowserTabAudio.workspaceToggleActionID, invocation: invocation)
        case .layout(let op):
            applyLayoutOp(op)
        case .dropOnLayoutSection(let ids, let section, let index):
            let storedIndex = services.sidebarLayout.document.storedInsertionIndex(index, in: section, from: model.layout)
            PinCommands(context: AppActionContext(services: services)).userDrop(ids.map(\.rawValue), on: section, at: storedIndex)
        case .toggleLayoutSection:
            model.apply(intent)
        case .setIcon, .setGroupPinned, .setGroupIcon, .openGroup, .groupEditorEnded:
            // Needs daemon fields this build does not map yet; apply locally
            // so the UI responds, the next store change restores truth.
            model.apply(intent)
        }
    }

    /// `set-workspace-metadata` with the pin, per owning daemon. A daemon
    /// without `workspace-pin-v1` keeps the row where it was.
    private func sendPinned(_ ids: [SidebarWorkspaceID], _ pinned: Bool) {
        for (daemon, key) in keys(ids) {
            guard daemon.supports(DaemonCapabilities.workspacePin) else {
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

    /// Refuses an organization intent that personal state cannot take.
    func refuseOrganization() {
        services.registry.refuse(services.machines.local.personalStateUnavailableReason)
        resync()
    }

    /// Puts daemon truth back after a refused or rejected intent.
    func resync() {
        guard let state else { return }
        model.ungroupedFirst = !usesMixedOrder
        var sections = Self.sections(services.machines, members: services.windows.registry.members(of: state.id), profile: state.profileID,
                                     hidesHome: Self.hidesHome(services.sidebarLayout.document), selection: state.selection,
                                     newTabPages: Self.newTabPages(services.agentTabs, in: services.machines.local.store), muted: services.notifications.preferences.mutedWorkspaces,
                                     harnessIcons: { [weak services] in services?.harnessIconLookup ?? .none })
        sections = WorkspaceGroupConfigLook(config: services.settings?.snapshot.workspaceGroups ?? WorkspaceGroupConfig(), machines: services.machines)
            .applying(to: sections)
        // A connecting SSH machine keeps its pending row through a resync (cx-gaq9).
        if !model.groupsByComputer { sections = SSHConnectingRows.adding(services.machines, to: sections) }
        rows.show(sections)
        model.profiles = SidebarSpaceBar.profiles(services.machines.local)
        groupFlow.openPendingEditor()
    }

    /// Sends one command, shown at once through the store's intent log when
    /// it has an `intent`; a failure re-syncs the sidebar.
    private func command(_ label: String, on daemon: DaemonService, intent: Intent? = nil,
                         _ body: @escaping DaemonCommandBody) {
        // The intent goes in the store in this turn, with the row's own update, so no recompute between shows the old value.
        let send = intent.map { daemon.intendNow(label, $0, transaction: .generate(), body) }
        Task { [weak self, services] in
            let ok = if let send { await send() != nil } else { await daemon.request(label, body) != nil }
            if !ok { withExtendedLifetime(services) { self?.resync() } }
        }
    }
}
