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
        if case let .toggleCollapse(.group(group)) = intent, let doc = services.sidebarDoc.activeStore,
           let shown = model.group(group)?.isCollapsed {
            rows.edits.foldShown(group, collapsed: !shown)
            doc.setGroupCollapsed(group.rawValue, !shown) { [weak self] in self?.rows.edits.dropFold(group) }
            return
        }
        if CloudCreationRows.handle(intent, bridge: self, state: state) || services.sidebarDoc.handle(intent, bridge: self) { return }
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
                return sendPinned(unpinned, true, edit: rows.edits.add(intent), for: intent)
            case .machine(let machine):
                let target = services.machines.daemon(machine: machine.rawValue)
                let leaving = ids.filter { id in
                    guard let (workspace, daemon) = services.machines.workspace(id: id.rawValue) else { return false }
                    return workspace.pinned && daemon === target
                }
                // The reorder's own pending edit (below) shows the rows leaving Pinned.
                if !leaving.isEmpty { sendPinned(leaving, false, edit: nil, for: .setPinned(leaving, false)) }
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
        case .reorder(let ids, let position):
            // A pending edit, as on the personal path: each command's echo shows no step between.
            SidebarDaemonReorder.reorder(ids, to: position, in: model.sections, edit: rows.edits.add(intent), bridge: self)
        case .rename(let id, let name):
            model.apply(intent)
            guard let (workspace, daemon) = services.machines.workspace(id: id.rawValue), let key = workspace.key else { return }
            command("rename-workspace", on: daemon, for: intent, change: .renameWorkspace(key: key, name: name)) { c in _ = try await c.renameWorkspace(key, to: name) }
        case .close(let ids):
            // The row's close button is an entrypoint of `closeWorkspace`,
            // so it asks the same confirmation and ends the terminals too.
            // Several selected rows (Cmd-W, the row menu's Close, Delete) close as one batch.
            if ids.count > 1 { return WorkspaceSelectionClose.close(ids.map(\.rawValue), in: state, services) }
            for id in ids { services.registry.perform("closeWorkspace", invocation: ActionInvocation(closingRow: id.rawValue)) }
        case .newWorkspace(let machine, let group):
            // The plain "+" in a local window: the person's New Workspace, as Cmd-N (the Cloud toggle applies).
            if machine == nil, group == nil, state.machineID == MachineRegistry.localID {
                services.registry.perform("newTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .window, id: state.id), origin: .user))
                return
            }
            // A double-click in a group's empty part, or its "+": that group, where `workspaces.newPlacement` puts a
            // new workspace in it (its top under the default `top`).
            let daemon = machine.flatMap { services.machines.daemon(machine: $0.rawValue) }
                ?? services.machines.daemon(machine: state.machineID)
            // A machine turned off by policy (DisabledFeatures) gets nothing, not a local stand-in.
            if machine != nil || state.machineID != MachineRegistry.localID, daemon == nil { return }
            let rule = NewWorkspacePlacements.rule(for: state.id, in: services.windows)
            let slot = group.map { rule.slot(inGroup: $0, members: model.group($0)?.workspaces.map(\.id.rawValue) ?? []) }
            services.windows.newWorkspace(in: state, on: daemon, at: slot)
        case .setColor(let ids, let color):
            model.apply(intent)
            for (daemon, key) in keys(ids) {
                let update: FieldUpdate<String> = color.map { .set($0.rawValue) } ?? .clear
                let resource = daemon.store.stateResourceID(workspace: key)
                // A store intent (#25657): the color stays through every live recompute until the reply settles it,
                // and a refusal takes it back; without it the next recompute showed the old color until the echo.
                command("set-workspace-metadata", on: daemon, for: intent, change: .setWorkspaceColor(key: key, color: color?.rawValue)) { c in try await c.state.setWorkspaceIdentity(key, resource: resource, color: update) }
            }
        case .toggleCollapse, .createGroup, .move, .renameGroup, .setGroupColor, .ungroup, .reorderGroup:
            // Workspace groups are personal (the home session's
            // `workspace_group.*`, `handlePersonal`); the shared group
            // commands are not used, so the daemon can drop them. Before personal state loads it waits.
            if !organizationQueue.hold(intent, local: services.machines.local) { refuseOrganization() }
        case .closeGroup(let group):
            let members = (model.group(group)?.workspaces ?? []).compactMap { services.machines.workspace(id: $0.id.rawValue) }
            // One gesture, one closed group per daemon: one Reopen Closed brings the group's workspaces back.
            var closes: [(label: String, daemon: DaemonService, body: DaemonCommandBody)] = []
            WorkspaceClose.close(members) { daemon, label, body in closes.append((label, daemon, body)) }
            // A pending edit until every close is in its store (#26382): the rows leave in this turn and no live
            // recompute shows them again; a failed close brings back what did not close and says why.
            rows.send(rows.edits.add(intent), closes, failed: saveFailed(intent))
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
            command("move-profile", on: services.machines.local, for: intent) { c in try await c.moveProfile(id, to: index) }
        case .setPinned(let ids, let pinned):
            sendPinned(ids, pinned, edit: rows.edits.add(intent), for: intent)
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

    /// `set-workspace-metadata` with the pin, per owning daemon, for `intent`. `edit` (the pending edit that shows the
    /// pin, #26382) holds until every daemon's store has it, or a failure takes it back and says why. A daemon without
    /// `workspace-pin-v1` gets nothing and says so: its rows go back where they were when the edit settles.
    private func sendPinned(_ ids: [SidebarWorkspaceID], _ pinned: Bool, edit: SidebarPendingEdits.Token?, for intent: SidebarIntent) {
        let owners = keys(ids), failed = saveFailed(intent)
        let commands = owners.filter { $0.0.supports(DaemonCapabilities.workspacePin) }.map { daemon, key in
            (label: "set-workspace-metadata", daemon: daemon, body: { c in _ = try await c.setWorkspaceMetadata(key, pinned: pinned) } as DaemonCommandBody)
        }
        if commands.count < owners.count { failed(ActionWorkFailure(RefusalStrings.needsDaemonCapability(DaemonCapabilities.workspacePin))) }
        guard !commands.isEmpty else {
            rows.edits.settle(edit)
            return resync()
        }
        rows.send(edit, commands, failed: failed)
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

    /// What a failed save of `intent` does (#26382): the rows show their owner's state again, and the person sees
    /// why where refusals show ("<change> did not apply: <reason>", `SidebarIntent.saveAction`).
    func saveFailed(_ intent: SidebarIntent) -> @MainActor (ActionWorkFailure) -> Void {
        { [weak self] failure in
            guard let self else { return }
            resync()
            let action = intent.saveAction
            services.registry.reportFailure(of: ActionID(rawValue: action.id), title: action.title, failure)
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
        model.ungroupedFirst = !services.sidebarDoc.isActive && !usesMixedOrder
        let shownAt = services.sidebarDoc.store?.shownChanges
        var sections = Self.sections(services.machines, doc: services.sidebarDoc, members: services.windows.registry.members(of: state.id), profile: state.profileID,
                                     hidesHome: Self.hidesHome(services.sidebarLayout.document), selection: state.selection,
                                     newTabPages: Self.newTabPages(services.agentTabs, in: services.machines.local.store), muted: services.notifications.preferences.mutedWorkspaces,
                                     harnessIcons: { [weak services] in services?.harnessIconLookup ?? .none })
        sections = WorkspaceGroupConfigLook(config: services.settings?.snapshot.workspaceGroups ?? WorkspaceGroupConfig(), machines: services.machines)
            .applying(to: sections)
        // A connecting SSH machine keeps its pending row through a resync (cx-gaq9).
        if !model.groupsByComputer { sections = SSHConnectingRows.adding(services.machines, to: sections) }
        rows.show(sections, shownAt: shownAt)
        model.profiles = SidebarSpaceBar.profiles(services.machines.local, window: state.id, windows: services.windows)
        groupFlow.openPendingEditor()
    }

    /// Sends one command for `intent`, shown at once through the store's intent log when it has a store
    /// `change`; a failure re-syncs the sidebar and says why (#26382).
    private func command(_ label: String, on daemon: DaemonService, for intent: SidebarIntent, change: Intent? = nil,
                         _ body: @escaping DaemonCommandBody) {
        // The change goes in the store in this turn, with the row's own update, so no recompute between shows the old value.
        let send = change.map { daemon.intentSender(label, $0, body) }, failed = saveFailed(intent)
        // task-owner: one sidebar command; reports its failure
        Task { [services] in
            let failure = if let send { await send() } else { await daemon.failure(label, body) }
            if let failure { withExtendedLifetime(services) { failed(failure) } }
        }
    }
}
