import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextHome
import CmuxNextLayout
import CmuxNextSettings
import CmuxNextSidebar
import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

extension AppActions {
    static func bindWorkspaces(_ services: AppServices) {
        let registry = services.registry
        registry.bind("newTab", invoke: { newWorkspace(services, $0) })
        registry.bind("closeWorkspace", invoke: { closeWorkspace(services, $0) })
        registry.bind("renameWorkspace", invoke: { invocation in
            guard let workspace = scope(services, invocation).workspace, let key = workspace.key else { return }
            if let name = invocation["name"]?.stringValue, !name.isEmpty {
                // The daemon that owns the workspace (a remote host's row too), not the active window's.
                let daemon = services.machines.daemon(forWorkspace: workspace.id) ?? services.activeDaemon
                daemon.send("rename-workspace") { _ = try await $0.renameWorkspace(key, to: name) }
                return
            }
            guard let window = renameRowWindow(workspace, services, builds: true) else {
                return services.registry.refuse(renameRowReason(workspace, services) ?? RefusalStrings.workspaceNotInSidebar)
            }
            // The name field opens on the row in the window that lists it, which comes forward.
            if window !== services.windows.active { services.windows.bringToFront(window) }
            window.sidebar.container.beginRename(workspace: SidebarWorkspaceID(workspace.id))
        })
        AppActionContext(services: services).setTargetReason("renameWorkspace") { [weak services] invocation in
            guard let services, invocation["name"]?.stringValue?.isEmpty ?? true, let workspace = scope(services, invocation).workspace else { return nil }
            return renameRowReason(workspace, services)
        }
        // Next / previous sidebar item and Cmd-1…9: one walk over every
        // visible item in shown order (SIDEBAR-NUMBERING-AND-STEPPING).
        // Workspaces as tabs' Cmd-Shift-] / [ pass `scope` (workspaces only, wrapping); the table holds them
        // only while its Debug tunable is on.
        // From a key, the item one more step that way prewarms (`directionalPrewarm`).
        registry.bindEffect("nextSidebarTab", effect: { SidebarNavigation.stepAction(by: 1, $0, services) })
        registry.bindEffect("prevSidebarTab", effect: { SidebarNavigation.stepAction(by: -1, $0, services) })
        registry.includesWorkspaceTabKeys = { SidebarTunables.workspacesAsTabs.value }
        registry.bind("selectWorkspaceByNumber", invoke: { invocation in
            guard let number = invocation["index"]?.intValue else { return }
            SidebarNavigation.select(number: number, services)
        })
        // The native Home tab (HomePageTab), the channels Home tab (HomeChannelsPageTab) and in DEBUG the Home
        // fixture: registered at launch so a restored tab finds its provider (not blank).
        services.pages.register(HomePageTab(services: services))
        registry.bind("home.tab", invoke: { _ = HomePageTab.open(services, focus: $0.allowsViewChange) })
        services.pages.register(HomeChannelsPageTab.make(services))
        // The docked Home's tab (HomeDockTab): the Messages or Channels view (the sidebar's Home or Channels entry).
        services.pages.register(HomeDockTab(services: services))
        #if DEBUG || CMUX_BENCH_HOOKS
        services.pages.register(DebugHomeNativeFixture(openPanel: services.openPanel, deadlines: services.mainDeadlines, work: services.work))
        #endif
        registry.bind("home.channels") { _ = HomeChannelsPageTab.open(services) }
        // Home = the home workspace and its left dock (cx-ebm.59.5), in the active window or the one that has it;
        // the sidebar's Home entry, so a dock showing Channels goes back to Messages (cx-frn2y).
        registry.bind("home.show") { if showHome(services), services.home.dockMode == .channels { HomeDockTab.view(services)?.switchTo(.messages) } }
        services.lifetimeFollowers.append(HomeSettingActions().bind(
            into: registry, settings: { [weak services] in services?.settings }, unavailable: RefusalStrings.homeNotReady, mainWork: services.mainWork,
            summonChiefPet: { [weak services] petOn in services?.notifications.chiefPet?.summon(petOn: petOn) }))
        // The composer's attach button as an action (home.attachFiles): a path
        // goes to the shown Home composer through its own intake (as a drop);
        // without one the shown composer opens its file picker.
        registry.bind("home.attachFiles", invoke: { invocation in
            guard let view = HomeNativeTranscriptView.shown(in: services.windows.active?.window), view.canAttach else {
                services.registry.refuse(RefusalStrings.homeAttachNoHome)
                return
            }
            guard let path = invocation["path"]?.stringValue, !path.isEmpty else {
                view.pickFiles()
                return
            }
            if view.attachFiles(paths: [path], via: .drop) == .missingFile {
                services.registry.refuse(RefusalStrings.homeAttachNoFile(path))
            }
        })
        // Reply to Selection (Cmd-Shift-R on Home, the palette): the same path as the transcript's menu item.
        registry.bind("home.replyToSelection") {
            guard let view = HomeNativeTranscriptView.shown(in: services.windows.active?.window), view.replyToSelection() else {
                services.registry.refuse(RefusalStrings.homeReplyNoSelection)
                return
            }
        }
        // The Home page's New Message, Invite, New Chief, Archive Chief and Open Conversation.
        bindHomeConversations(services)
        bindHomeGroups(services)
        bindHomeMessaging(services)
        // Debug > Save Last 10 Seconds (DEV and NIGHTLY): MessagesLab's flight recorder dump.
        registry.bind("home.saveFlightRecording") {
            if HomeFlightRecording.saveLastSeconds() == nil { services.registry.refuse(RefusalStrings.homeFlightRecorderOff) }
        }
                registry.bind("moveWorkspaceUp", invoke: { moveWorkspace(services, $0, by: -1) })
        registry.bind("moveWorkspaceDown", invoke: { moveWorkspace(services, $0, by: 1) })
    }

    /// Why Rename Workspace with no name cannot open a name field for `workspace`, or nil: a
    /// workspace no window's sidebar lists has no row to edit (Home, while the sidebar shows it as
    /// its Home item, keeps its name).
    static func renameRowReason(_ workspace: WorkspaceModel, _ services: AppServices) -> String? {
        guard renameRowWindow(workspace, services) == nil else { return nil }
        // A restored window still waiting for its launch build lists the row once built (the rename builds it).
        if let owner = services.windows.registry.value.owner(of: workspace.id), services.windows.launchWindows?.isWaiting(owner) == true { return nil }
        return HomeRules.isHome(workspace) ? RefusalStrings.homeKeepsItsName : RefusalStrings.workspaceNotInSidebar
    }

    /// The window whose sidebar lists `workspace`'s row: the window that owns it, else the active one.
    /// `builds`: the rename itself, which acts in that window, builds it when it waits for its launch build.
    static func renameRowWindow(_ workspace: WorkspaceModel, _ services: AppServices, builds: Bool = false) -> WindowController? {
        let windows = services.windows
        let owner = windows.registry.value.owner(of: workspace.id).flatMap { builds ? windows.controllerBuildingIfWaiting(for: $0) : windows.controller(for: $0) }
        return [owner, windows.active].compactMap { $0 }.first { $0.sidebar.model.workspace(SidebarWorkspaceID(workspace.id)) != nil }
    }

    /// New workspace (`WorkspaceSpawn` arguments: the New Tab page for a
    /// person, one terminal for a script or a `command`), shown
    /// in the active window unless `focus` is false (the CLI's default).
    /// With `activate: true` as well (`cmux open <dir>` run by a person) it
    /// also brings that window forward and activates the app
    /// (`NewWorkspaceFocus`).
    private static func newWorkspace(_ services: AppServices, _ invocation: ActionInvocation) {
        // Who asked: the run's own origin (a handler's nested run keeps its outer run's, ActionRouting), not the handed
        // invocation's, which a nested run builds with the default user origin.
        let byPerson = (ActionRunScope.current?.origin ?? invocation.origin) == .user
        var spawn = WorkspaceSpawn(invocation)
        // Only the person's own run opens the New Tab page (and its key hold); automation gets a terminal.
        if !byPerson { spawn.opensNewTabPage = false }
        // The press's own key or click (or the stamp a gate carried), so its row's create.workspace reports that age.
        if byPerson {
            spawn.inputTimestamp = ActionRegistry.inputTimestamp(of: services.registry.dispatchingInputEvent()) ?? invocation.inputTimestamp
        }
        spawn.followClassicMode(services) // before the key hold below, which waits only for a page
        let focus = NewWorkspaceFocus(invocation)
        let show = focus.shows
        // A person's Cmd-N starts where they work: the focused terminal's folder or the focused
        // agent chat's exact folder, unless `window-inherit-working-directory = false`.
        if byPerson, invocation["machine"] == nil, NewTerminalStart.inherits(.window),
           let focused = services.windows.active?.focusedPane, focused.daemon === services.daemon {
            spawn.inheritedCwd = NewTerminalStart.inherited(besides: focused.selectedTab, in: focused.pane, services: services)
        }

        let windows = services.windows
        // Shown: the active window, or a new one when none is open. Not
        // shown (the CLI default): the most recent window lists it, or a new
        // window when none is open (a workspace never lives in no window).
        let hasOpenWindow = !windows.registry.value.openWindows.isEmpty
        let target: String? = show || !hasOpenWindow ? windows.targetWindow(preferring: windows.activeWindowID) : nil
        // `machine` (App machine id; the CLI's `--session`): born on that
        // session's daemon (plans/cmux-next/data-model.md 1.3).
        let daemon = (invocation["machine"]?.targetValue?.id ?? invocation["machine"]?.stringValue).flatMap(services.machines.daemon(machine:))
        if invocation["machine"] != nil, daemon?.connection == nil {
            services.registry.track(Task { ActionWorkFailure(WorkspaceVerbStrings.machineNotConnected) })
            return
        }
        // A person's Cmd-N onto the New Tab page in the window they type in: every key from this
        // moment waits for the new page's field, in order (cx-kql5h), not for the workspace to show.
        let input = services.keyRouter.newTabInputCoordinator
        let opensPage = show && hasOpenWindow && spawn.opensNewTabPage && spawn.command == nil && spawn.firstChat == nil
            && spawn.firstSession == nil && services.agentTabs.opensFirstPage(on: daemon ?? services.daemon)
        let keys = opensPage && target == windows.active?.state.id ? input.beginIncoming(in: windows.active?.window) : nil
        spawn.inputToken = keys
        // The person's own new workspace with a terminal (a terminal-first Cmd-N, the menu, the palette) shown in the
        // window they type in: every key from this moment is that terminal's, it waits for it, and the window's keyboard
        // stays the terminal's until the person's next intent there (dogfood v2.2.3: the keys went to the Chief as a
        // message). A script's newTab holds no key of the person's: automation never competes with them.
        let terminalWindow = byPerson && show && hasOpenWindow && target == windows.active?.state.id
            && !WorkspaceCreation.opensPage(spawn, on: daemon ?? services.daemon, tabs: services.agentTabs) ? windows.active : nil
        let terminalKeys = services.keyRouter.creationInputCoordinator.beginWorkspace(in: terminalWindow)
        let keyWindow = terminalWindow?.window
        // Automation never competes with the person (CLAUDE.md, "Go past Chrome where cmux is scripted"): a script's,
        // the CLI's, MCP's or the socket's new workspace with focus is made and listed without being shown, and the window
        // shows it once it exists only if no text input has the person's keyboard then (`hasTextInputKeyboard`): decided
        // when it would show, so a person who started typing meanwhile keeps their input.
        let quiet = !byPerson && show && hasOpenWindow ? ActionRunScope(origin: ActionRunScope.current?.origin ?? invocation.origin, allowsViewChange: false) : nil
        // In this turn: the row, and for Cmd-N's page the workspace itself, show before any daemon reply.
        let create: () async throws -> String = BenchSpans.measure("cmdN.start") {
            guard let quiet else { return windows.startWorkspace(spawn, on: daemon, into: target) }
            return ActionRunScope.carrying(quiet) { windows.startWorkspace(spawn, on: daemon, into: target) }
        }
        // A script's create runs without view change, its tasks included; the show below asks for it again.
        let run = { services.registry.track(Task {
            var pageMade = false
            var made: String?
            defer {
                input.endIncoming(keys, pageMade: pageMade)
                services.keyRouter.creationInputCoordinator.resolve(terminalKeys, workspace: made, in: keyWindow)
            }
            do {
                made = try await create(); BenchSpans.mark("cmdN.created")
                pageMade = true
                // A window with no controller yet (a launch window still to build, a new one) has nobody typing in it.
                if let quiet, let made, let target, windows.controller(for: target)?.hasTextInputKeyboard != true {
                    // Claimed again, out loud: shown now when the store has it, else when it lists it (reconcile).
                    windows.quietClaims.remove(made)
                    let shows = ActionRunScope(origin: quiet.origin, allowsViewChange: true)
                    ActionRunScope.carrying(shows) {
                        windows.claimNew(workspaceID: made, window: target)
                        if focus.activatesApp { focusWindow(windows, target) }
                    }
                } else if quiet == nil, focus.activatesApp, let target {
                    focusWindow(windows, target)
                }
                return nil
            } catch is CancellationError {
                return nil // a close took it before it started (WorkspaceLanes)
            } catch {
                services.daemon.logger.error("create workspace failed: \(String(describing: error), privacy: .public)")
                return ActionWorkFailure("new workspace", error)
            }
        }) }
        if let quiet { ActionRunScope.carrying(quiet, run) } else { run() }
    }

    /// Close Workspace. With no target, a close pressed while the window's
    /// creates are outstanding takes the newest of them (the workspace the
    /// person just asked for, not yet shown), never the one the window still
    /// shows (cx-7cit9). Otherwise it closes the scoped workspace after the
    /// window's earlier creates and closes (`WorkspaceLanes`). The workspace
    /// is resolved at the press and its row leaves then; a person's run asks
    /// about running programs afterwards (`WorkspaceCloseFlow`).
    private static func closeWorkspace(_ services: AppServices, _ invocation: ActionInvocation) {
        let window = services.windows.active?.state.id
        let lanes = WorkspaceLanes.shared
        if invocation.target == nil, invocation["workspace"] == nil, let window,
           lanes.closeNewestCreate(in: window, listed: { services.workspace(id: $0) != nil }, taken: PendingWorkspaceRows.shared.remove) { return }
        guard let workspace = scope(services, invocation).workspace, let key = workspace.key,
              !ClosingWorkspaces.shared.ids.contains(workspace.id), !WorkspaceCloseFlow.running.contains(workspace.id)
        else { return } // a second press during the close sends nothing
        // A person's close of one of several selected rows closes them all, as the sidebar's Delete does.
        if invocation.origin == .user, !invocation.closesRowOnly, let sidebar = services.windows.registry.value.owner(of: workspace.id).flatMap(services.windows.controller(for:))?.sidebar.model,
           case let ids = sidebar.closeTargets(for: SidebarWorkspaceID(workspace.id)), ids.count > 1 { return sidebar.send(.close(ids)) }
        // The workspace's own machine, for the question and the close alike. `offline`: a person's close on a machine that is
        // not connected (a paused Cloud VM): its row leaves as any other, and the close waits for the machine outside the
        // window's lane (later creates and closes never wait for it) until it connects or leaves the app (the row then lists
        // again); a row that cannot hide says why. CLI and socket closes still fail at once.
        let daemon = services.machines.daemon(forWorkspace: workspace.id) ?? services.activeDaemon, offline = !daemon.isLive && invocation.origin == .user
        let terminals = WorkspaceClose.closing(workspace, on: daemon), id = workspace.id, owner = services.windows.registry.value.owner(of: id)
        let controller = owner.flatMap(services.windows.controller(for:)), shownAtPress = controller?.state.workspaceID == id
        let warn = services.settings?.snapshot.warnBeforeClosingTab ?? CmuxConfigSnapshot.closeWarningFallback, selected = WorkspaceCloseSelection()
        let flow = WorkspaceCloseFlow(
            // Instant (ClosingWorkspaces): the row starts closing and the selection moves now, in one sidebar pass.
            hide: {
                let hidden = InstantClose.begin(id, in: owner, windows: services.windows)
                selected.afterPress = controller?.state.workspaceID
                return hidden
            },
            // The question, when a terminal runs a program: on the window that lists the workspace, above its pages.
            question: {
                guard var prompt = await WorkspaceBulkClose.prompt([(workspace, daemon)], warn: warn) else { return nil }
                prompt.returnConfirms = false
                return {
                    // A question that goes unanswered is a no.
                    (try? await withOnceContinuation { (answer: OnceContinuation<Bool, OnceContinuationError>) in
                        DestructiveConfirmation.present(prompt, in: controller?.window ?? services.windows.active?.window,
                                                        settings: services.settings) { answer.resume(returning: $0) }
                    }) ?? false
                }
            },
            // Closed another way while the question was up (the CLI, another window): nothing to send or bring back.
            exists: { services.workspace(id: id) != nil },
            send: { hidden in
                let close: @MainActor () async -> ActionWorkFailure? = {
                    let failure = await daemon.failureOnceConnected("close-workspace", waits: offline, while: { services.machines.daemons.contains { $0 === daemon } }) { connection in
                        try await ClosingWorkspaces.shared.refusal()
                        try await WorkspaceClose.close(key, terminals: terminals, on: connection)
                    }
                    guard hidden else { return failure }
                    // A close that went through stays hidden until the store has applied its events (the row is gone there).
                    if failure == nil, let connection = daemon.connection { await daemon.appliedThroughReply(on: connection, after: "close workspace") }
                    ClosingWorkspaces.shared.end(id, refused: failure != nil, in: controller?.window)
                    return failure
                }
                return !offline ? lanes.run(in: window, close) : hidden ? Task { await close() } : Task { services.registry.refuse(CloudStrings.closeNotConnected(services.machines.machineName(daemon.machineID) ?? daemon.machineID)); return nil }
            },
            // Cancel: the row is listed again, and the window shows it again unless the person moved on meanwhile
            // (or it closed another way meanwhile).
            restore: { hidden in
                guard hidden else { return }
                ClosingWorkspaces.shared.end(id, refused: false, in: nil)
                if shownAtPress, services.workspace(id: id) != nil, let controller, controller.state.workspaceID == selected.afterPress {
                    services.windows.show(workspaceID: id, in: controller.state)
                }
            })
        if let work = flow.start(id, asks: invocation.asksIfRunning) { services.registry.track(work) }
    }

    /// Makes window `id` key and activates the app. A new window still
    /// waiting for its first workspace comes to the front when that shows.
    private static func focusWindow(_ windows: WindowManager, _ id: String) {
        guard windows.ordersWindowsIn, let controller = windows.controllerBuildingIfWaiting(for: id) else { return }
        if windows.awaitingContent[id] != nil {
            windows.bringToFront(controller)
            WindowActivation.activateApp()
            return
        }
        guard let window = controller.window else { return }
        WindowActivation.show(window, .focus)
        windows.didActivate(controller)
    }

    private static func moveWorkspace(_ services: AppServices, _ invocation: ActionInvocation, by offset: Int) {
        // A person's Move Up/Down on one of several selected rows moves them as one block, as Cmd-Opt-Up/Down does.
        if invocation.origin == .user, let workspace = scope(services, invocation).workspace,
           let sidebar = services.windows.registry.value.owner(of: workspace.id).flatMap(services.windows.controller(for:))?.sidebar.model,
           case let id = SidebarWorkspaceID(workspace.id), sidebar.actionTargets(for: id).count > 1 {
            sidebar.moveActionTargets(of: id, offset < 0 ? .up : .down)
            return
        }
        if services.machines.local.store.personal.isLoaded { return movePersonalWorkspace(services, invocation, by: offset) }
        let store = services.activeDaemon.store
        guard let workspace = scope(services, invocation).workspace, let key = workspace.key,
              let index = store.workspaces.firstIndex(where: { $0 === workspace }) else { return }
        // Up/down among the workspaces its window lists: the daemon index of
        // the neighbor in that window (other windows' workspaces are skipped).
        let members = Set(services.windows.registry.value.owner(of: workspace.id).map(services.windows.registry.members(of:)) ?? [])
        let visible = store.workspaces.filter { members.isEmpty || members.contains($0.id) }
        guard let position = visible.firstIndex(where: { $0 === workspace }), visible.indices.contains(position + offset),
              let target = store.workspaces.firstIndex(where: { $0 === visible[position + offset] }), target != index else { return }
        let daemon = services.activeDaemon
        Task {
            await daemon.intend("move-workspace", .moveWorkspace(key: key, index: target)) { connection in
                _ = try await connection.moveWorkspace(key, to: target)
            }
        }
    }
}
