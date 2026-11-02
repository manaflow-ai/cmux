import AppKit
import CmuxNextActions
import CmuxNextAgentLanes
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextComputerUse
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextHistory
import CmuxNextHomeEngine
import CmuxNextMacScreen
import CmuxNextOnboarding
import CmuxNextSettings
import Observation

/// Agent actions. Fork Conversation (``AgentForkDestination``): an agent chat tab forks through
/// its page (`chat.forkTo`) and opens the fork at the destination (`AgentTabStore.openFork`); a
/// terminal forks the agent session the daemon reports for it (`TabModel.agent`, from
/// `list-agents` state) by its CLI (`claude --resume <session> --fork-session`, `codex fork
/// <session>`) in a new terminal placed by daemon commands. New Agent Chat opens the React acpmux pane in a tab
/// (CmuxNextAgentPane), and Toggle Dictation drives its composer's mic.
/// Start Agent toggles the floating `QuickComposerController` panel.
/// Computer Use Setup and its two grants run `ComputerUseSetup`.
/// Launch Claude/Codex Teams run `AgentTeamsLaunch`. Computer Use
/// focus/stop are typed-unavailable.
enum AgentHandlers {
    /// Inspect Element (#24707): every right-click menu that places it (the tab bar's + among
    /// them) leaves it out while Debug Settings' UI pointer inspector
    /// (`AgentPaneTunables.pointerInspector`, on by default) is turned off.
    static func gatePointerInspectorMenuRows(in registry: ActionRegistry) {
        ActionTargetVisibility.hide("agentPane.togglePointerInspector", in: registry) { _ in
            !AgentPaneTunables.pointerInspector.value
        }
    }

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("agentPaneZoomIn", run: { invocation in try setAgentPaneZoom(by: AgentPaneZoomSetting.step, context: context, invocation: invocation) })
        registry.bind("agentPaneZoomOut", run: { invocation in try setAgentPaneZoom(by: -AgentPaneZoomSetting.step, context: context, invocation: invocation) })
        registry.bind("agentPaneZoomReset", run: { invocation in try resetAgentPaneZoom(context, invocation: invocation) })
        // The Chief chat follows the same setting (HomeNativeTranscriptView.followZoom): no view to look up.
        registry.bindEffect("home.zoomIn", requires: nil, effect: { _ in
            try stepAgentPaneZoom(by: AgentPaneZoomSetting.step, context: context)
            return .done
        })
        registry.bindEffect("home.zoomOut", requires: nil, effect: { _ in
            try stepAgentPaneZoom(by: -AgentPaneZoomSetting.step, context: context)
            return .done
        })
        registry.bindEffect("home.zoomReset", requires: nil, effect: { _ in
            try resetAgentPaneZoom(context)
            return .done
        })
        registry.bindEffect("palette.forkAgentConversationTo", requires: nil, effect: { invocation in
            guard let (pane, id) = context.scope(invocation).tab, let tab = pane.tab(id),
                  let view = context.services.agentTabs.existingView(tab.id) else {
                throw ActionFailure(message: MiscHandlerStrings.noForkTarget)
            }
            view.chooseForkDestination()
            return .done
        })
        for (id, destination) in forkActions {
            // A new row needs rows on and `rows-v1`, as New Row does: disabled with that reason.
            let gatesOnRows = destination == .row
            registry.bindEffect(id, requires: nil, unavailable: { gatesOnRows ? ColumnHandlers.newRowUnavailableReason(context) : nil }, effect: { invocation in
                try fork(destination, offerDestinations: id == "palette.forkAgentConversation", invocation: invocation, context: context)
                return .done
            })
        }
        registry.bind("agentActivity.open", run: { _ in context.services.agentActivityPage.open() })
        context.services.pages.register(context.services.macScreenTabs)
        registry.bind("macScreen.open", run: { context.services.openMacScreen(in: try? context.pane($0)) })
        // The menu bar item's rows while a device sees or controls this Mac (MacScreenShareIndicator).
        registry.bind("macScreen.stopSharing", unavailable: { context.services.macScreenPages.hubHost.noSessionReason },
                      run: { _ in _ = context.services.macScreenPages.hubHost.stopSession() })
        registry.bind("macScreen.revokeViewer", unavailable: { context.services.macScreenPages.hubHost.noSessionReason },
                      run: { _ in _ = context.services.macScreenPages.hubHost.revokeViewer() })
        AgentSessionWorkspace.bind(into: registry, context: context)
        AgentSessionTab.bind(into: registry, context: context)
        ChiefInspectorHandlers.bind(into: registry, context: context)
        AddHarnessHandler.bind(into: registry, context: context)
        AgentHarnessHandlers.bind(into: registry, context: context)
        // The front window's Home, else the Chief directly (HomeChiefActions).
        HomeChiefActions.bind(into: registry, context: context)
        // Start Agent: its key, the palette, the menu and the CLI toggle one floating panel, and so
        // does Start Agent from Any App, its opt-in system-wide key (`app.startAgentGlobalHotKey`).
        // The panel takes the keyboard from the frontmost app, so automation
        // cannot open it unless it asks for focus.
        for id: ActionID in ["palette.quickAgentChat", "palette.startAgentFromAnyApp"] {
            registry.bind(id, run: { invocation in
                guard invocation.allowsViewChange else { return context.refuse(MiscHandlerStrings.quickChatNeedsFocus) }
                guard context.services.agentTabs.canHostChat else { return context.refuse(MiscHandlerStrings.quickChatUnavailable) }
                context.services.quickComposer.toggle()
            })
        }
        // A chat tab's Move to Floating Chat (cx-b9qi): the same panel holds its session.
        context.services.agentTabs.moveToFloatingChat = { [weak services = context.services] in services?.quickComposer.moveToFloatingChat(session: $0) ?? false }
        // Computer Use Setup: one model (`ComputerUseSetup`) behind the palette, the CLI, the
        // Settings card and the onboarding step. Setup opens the guided step; the two grant
        // actions open their Privacy & Security list.
        registry.bind("palette.computerUse.setup", run: { _ in
            context.services.onboarding.computerUseSetup.recheck()
            context.services.onboarding.show(step: .computerUse)
        })
        registry.bindEffect("palette.computerUse.restart", effect: { _ in
            guard let restart = context.services.onboarding.computerUseSetup.prepareRestart() else { return .done }
            return .applied(ActionConfirmation(send: {
                await restart()
                return nil
            }))
        })
        registry.bind("palette.computerUse.accessibility", run: { _ in context.services.onboarding.computerUseSetup.open(.accessibility) })
        registry.bind("palette.computerUse.screenRecording", run: { _ in context.services.onboarding.computerUseSetup.open(.screenRecording) })
        registry.bindAgentPane { invocation in
            if openOnHost(invocation, context: context) { return }
            openLocalChat(invocation, context: context)
        }
        registry.bindEffect("palette.newAgentChatOn", effect: { invocation in
            guard invocation["host"] != nil else { return .refused(WorkspaceVerbStrings.noMachine) }
            _ = registry.perform("palette.newAgentChat", invocation: invocation)
            return .done
        })
        registry.bindAgentPaneSessionInfo { invocation in
            focusedAgentView(context, invocation)?.toggleSessionInfo()
        }
        registry.bindAgentPageCommands(available: { invocation in
            // Read only: no refusal while the palette asks whether a row is enabled.
            let scope = context.scope(invocation)
            guard let key = scope.tab?.id.rawValue ?? scope.pane?.currentTabKey,
                  let model = context.services.agentTabs.existingView(key)?.model else { return nil }
            // The New Tab page runs none of the chat's controls.
            return model.newTab == nil ? model.pageCommands : []
        }, run: { command, invocation in
            focusedAgentView(context, invocation)?.run(command)
        })
        registry.bindAgentPaneInspector { invocation in
            guard let pane = context.scope(invocation).pane else { return context.refuse(MiscHandlerStrings.noPane) }
            guard let key = pane.currentTabKey, let view = context.services.agentTabs.existingView(key) else {
                return context.refuse(MiscHandlerStrings.noAgentPane)
            }
            view.toggleInspector()
        }
        registry.bind(.stopTurn, run: { invocation in
            guard let view = focusedAgentView(context, invocation) else { return }
            view.stopTurn()
        })
        registry.bind("agentPane.togglePointerInspector", unavailable: {
            AgentPaneTunables.pointerInspector.value ? nil :
                "UI pointer inspector is off. Turn it on in Debug Settings."
        }, run: { invocation in
            // Palette, keyboard and the CLI keep the existing toggle contract.
            // A targeted context-menu invocation starts at the right-click point.
            if invocation.target == nil {
                context.services.uiInspector.toggle()
            } else {
                context.services.uiInspector.inspectFromContextMenu()
            }
        })
        gatePointerInspectorMenuRows(in: registry)
        registry.bindEffect(.fileOpen, effect: { invocation in
            do {
                try openFile(invocation, context: context)
                return .done
            } catch {
                return .refused(ViewerService.reason(error))
            }
        })
        // The composer's mic (CmuxNextAgentPane). Held from the keyboard, it
        // is push-to-talk. Outside an agent chat it stops a session still
        // running in one.
        registry.bind("palette.toggleDictation", invoke: { invocation in
            guard let pane = context.scope(invocation).pane, let key = pane.currentTabKey,
                  let view = context.services.agentTabs.existingView(key) else {
                if AgentPaneView.stopDictation() { return }
                return context.refuse(MiscHandlerStrings.noAgentChat)
            }
            view.toggleDictation()
        })
        // Stop Reading Aloud: the app's one voice (AgentPaneReadAloud), from any window, chat or none.
        registry.bindEffect("agentPane.stopReadingAloud", requires: nil, effect: { _ in
            context.services.agentTabs.readAloud.stop() ? .done : .refused(MiscHandlerStrings.nothingReadAloud)
        })
        // Search Agent Chats (decision K1): the command palette's chats page, from anywhere.
        context.services.palette.sources.actionPages["agentPane.searchChats"] = { [weak services = context.services] in
            services.map { AgentChatsPalettePage(services: $0).page() }
        }
        registry.bind("agentPane.searchChats", run: { _ in
            context.services.palette.show(page: AgentChatsPalettePage(services: context.services).page(),
                                          relativeTo: context.activeWindow?.window)
        })
        let permissionCommands: [(ActionID, String)] = [
            ("agentPane.permission.allowOnce", "permissionAllowOnce"),
            ("agentPane.permission.allowChat", "permissionAllowChat"),
            ("agentPane.permission.deny", "permissionDeny"),
            ("agentPane.permission.expand", "permissionExpand"),
            ("agentPane.permission.retry", "permissionRetry"),
            ("agentPane.permission.revoke", "permissionRevoke"),
            ("agentPane.permission.refresh", "permissionRefresh"),
        ]
        for (id, command) in permissionCommands {
            registry.bind(id, run: { invocation in
                guard let pane = context.scope(invocation).pane, let key = pane.currentTabKey,
                      let view = context.services.agentTabs.existingView(key) else {
                    return context.refuse(MiscHandlerStrings.noAgentChat)
                }
                view.runPermissionAction(command, byPerson: invocation.origin == .user)
            })
        }
        // Previous and Next Turn and Bookmarked Prompt step the agent chat's transcript (cx-f7c).
        for step in AgentTranscriptStep.allCases {
            registry.bind(ActionID(rawValue: step.actionID), run: { invocation in
                guard let pane = context.scope(invocation).pane, let key = pane.currentTabKey,
                      let view = context.services.agentTabs.existingView(key) else {
                    return context.refuse(MiscHandlerStrings.noAgentChat)
                }
                view.step(step)
            })
        }
        // Continue In… is a user-facing chooser. Headless callers use the
        // acpmux-owned CLI operation, so automation cannot open this UI unless
        // it explicitly requests focus.
        registry.bind("agentPane.continueIn", run: { invocation in
            guard invocation.allowsViewChange else {
                return context.refuse(MiscHandlerStrings.continueInNeedsFocus)
            }
            guard let pane = context.scope(invocation).pane, let key = pane.currentTabKey,
                  let view = context.services.agentTabs.existingView(key) else {
                return context.refuse(MiscHandlerStrings.noAgentChat)
            }
            view.showContinueIn()
        })
        // The focused chat's page takes the keyboard, then opens the model picker, file search,
        // or `/btw`'s side-question composer. The gate is published live from Debug Settings.
        let keyboardCommands: [(ActionID, () -> String, () -> String, (AgentPaneView) -> Void)] = [
            ("agentPane.switchModel", { MiscHandlerStrings.switchModelNeedsFocus }, { MiscHandlerStrings.switchModelNeedsAgentChat }, { $0.showModelPicker() }),
            ("agentPane.searchFiles", { MiscHandlerStrings.pickerNeedsFocus }, { MiscHandlerStrings.searchFilesNeedsAgentChat }, { $0.showFileSearch() }),
            ("agentPane.sideQuestion", { MiscHandlerStrings.sideQuestionNeedsFocus }, { MiscHandlerStrings.sideQuestionNeedsAgentChat }, { $0.askSideQuestion() }),
        ]
        for (id, needsFocus, needsChat, run) in keyboardCommands {
            registry.bind(id, run: { invocation in
                guard invocation.allowsViewChange else { return context.refuse(needsFocus()) }
                guard let pane = context.scope(invocation).pane, let key = pane.currentTabKey,
                      let view = context.services.agentTabs.existingView(key) else { return context.refuse(needsChat()) }
                run(view)
            })
        }
        registry.publishSideSessions()
        registry.bind("agentPane.createCheckpoint", run: { invocation in
            guard invocation.allowsViewChange else {
                return context.refuse(MiscHandlerStrings.checkpointNeedsFocus)
            }
            guard let pane = context.scope(invocation).pane, let key = pane.currentTabKey,
                  let view = context.services.agentTabs.existingView(key), view.model.checkpointAvailable else {
                return context.refuse(MiscHandlerStrings.noAgentChat)
            }
            view.showCreateCheckpoint()
        })
        // Commit and Push run the changes view's own path. Headless callers
        // use the session host's `cmux git commit|push` instead.
        for (id, action) in [("agentPane.git.commit", AgentPaneGitAction.commit), ("agentPane.git.push", .push)] as [(ActionID, AgentPaneGitAction)] {
            registry.bind(id, run: { invocation in
                guard invocation.allowsViewChange else {
                    return context.refuse(MiscHandlerStrings.gitWriteNeedsFocus)
                }
                guard let pane = context.scope(invocation).pane, let key = pane.currentTabKey,
                      let view = context.services.agentTabs.existingView(key) else {
                    return context.refuse(MiscHandlerStrings.gitNeedsAgentChat)
                }
                view.runGitAction(action)
            })
        }
        TerminalChatHandler.bind(into: registry, context: context)
        AgentShareActions(host: context.services).bind(into: registry)
        AgentTeamsLaunch.bind(into: registry, context: context)
        let services = context.services
        let helper = ComputerUseHelperDaemon.shared
        ComputerUseHandlers.bind(
            into: registry,
            sessions: CuaComputerUseSessions(configuration: { helper.configuration },
                                             phase: { [weak services] in services?.onboarding.computerUseSetup.phase ?? .off },
                                             confirmRunning: { helper.confirmRunning() }),
            focus: AppComputerUseFocus(services: services))
    }

    private static let agentPaneZoomPath = AgentPaneZoomSetting.configPath

    private static func focusedAgentView(_ context: AppActionContext, _ invocation: ActionInvocation = ActionInvocation()) -> AgentPaneView? {
        let scope = context.scope(invocation)
        guard let pane = scope.pane,
              let key = scope.tab?.id.rawValue ?? pane.currentTabKey,
              let view = context.services.agentTabs.existingView(key) else {
            context.refuse(MiscHandlerStrings.noAgentChat)
            return nil
        }
        return view
    }

    private static func setAgentPaneZoom(by delta: Double, context: AppActionContext, invocation: ActionInvocation) throws {
        try AppearanceHandlers.requireUnmanaged(agentPaneZoomPath, context)
        guard let view = focusedAgentView(context, invocation) else { return }
        view.zoom = try stepAgentPaneZoom(by: delta, context: context)
    }

    private static func resetAgentPaneZoom(_ context: AppActionContext, invocation: ActionInvocation) throws {
        try AppearanceHandlers.requireUnmanaged(agentPaneZoomPath, context)
        guard let view = focusedAgentView(context, invocation) else { return }
        try resetAgentPaneZoom(context)
        view.zoom = AgentPaneZoomSetting.fallback
    }

    /// Steps `agentPane.zoom` by `delta` (clamped), live and in cmux.json, and shows the percent: the new zoom.
    @discardableResult
    private static func stepAgentPaneZoom(by delta: Double, context: AppActionContext) throws -> Double {
        try AppearanceHandlers.requireUnmanaged(agentPaneZoomPath, context)
        let current = context.services.settings.map { $0.snapshot.agentPaneZoom } ?? Double(context.design.agentPaneZoom)
        let next = min(max(current + delta,
                           AgentPaneZoomSetting.range.lowerBound), AgentPaneZoomSetting.range.upperBound)
        context.design.agentPaneZoom = CGFloat(next)
        context.writeSetting("set agent chat zoom", agentPaneZoomPath, .number(next), reloadOnFailure: true)
        SurfaceZoomIndicator.show(percent: Int((next * 100).rounded()), in: context.services.windows.active?.window)
        return next
    }

    /// `agentPane.zoom` back to 100%, live and in cmux.json.
    private static func resetAgentPaneZoom(_ context: AppActionContext) throws {
        try AppearanceHandlers.requireUnmanaged(agentPaneZoomPath, context)
        context.design.agentPaneZoom = CGFloat(AgentPaneZoomSetting.fallback)
        context.writeSetting("reset agent chat zoom", agentPaneZoomPath, nil, reloadOnFailure: true)
        SurfaceZoomIndicator.show(percent: 100, in: context.services.windows.active?.window)
    }

    static func openNewAgentChat(in pane: PaneController, invocation: ActionInvocation, context: AppActionContext) {
        // Preserve Cmd-I exactly when no optional argument was supplied. Explicit CLI/MCP
        // arguments use the same seed consumed by the palette and the page handshake.
        guard !invocation.arguments.isEmpty else {
            pane.newAgentTab()
            return
        }
        let requested = seed(for: invocation)
        // An explicit peer never inherits a path or draft from this Mac. Local argument-only
        // invocations override just the supplied values and keep the existing inheritance.
        guard requested.host == nil else {
            _ = pane.openAgentTab(seed: AgentPaneSeedSource(requested))
            return
        }
        let inherited = pane.agentSeedFromSelectedTab()
        _ = pane.openAgentTab(seed: AgentPaneSeedSource {
            var seed = await inherited?.peek() ?? AgentPaneSeed()
            seed.cwd = requested.cwd ?? seed.cwd
            seed.harness = requested.harness ?? seed.harness
            seed.model = requested.model ?? seed.model
            return seed
        })
    }

    static func seed(for invocation: ActionInvocation) -> AgentPaneSeed {
        let host = invocation["host"]?.targetValue?.id ?? invocation["host"]?.stringValue
        return AgentPaneSeed(cwd: invocation["cwd"]?.stringValue,
                      harness: invocation["harness"]?.stringValue,
                      model: invocation["model"]?.stringValue,
                      host: host == MachineRegistry.localID ? nil : host)
    }

    /// Fork Conversation's actions, in the palette step's order (the default destination first).
    static let forkActions: [(ActionID, AgentForkDestination)] = [("palette.forkAgentConversation", .default)]
        + AgentForkDestination.allCases.map { ($0.actionID, $0) }

    /// The destination fork action `id` opens at, or nil for another action.
    static func destination(of id: ActionID) -> AgentForkDestination? {
        forkActions.first { $0.0 == id }?.1
    }

    /// How the terminal agent `status` forks: by the harness's own session id (a hook's
    /// `agent_session_id`; its `session` is only a label).
    static func terminalFork(_ status: AgentStatus?) -> TerminalAgentFork {
        .route(agent: status?.agent, session: status?.harnessSessionID)
    }

    private static func fork(_ destination: AgentForkDestination, offerDestinations: Bool, invocation: ActionInvocation, context: AppActionContext) throws {
        guard let (pane, id) = context.scope(invocation).tab, let tab = pane.tab(id) else {
            throw ActionFailure(message: MiscHandlerStrings.noForkTarget)
        }
        // An agent chat (a Home chat, a subagent chat, a chat on another machine): its page forks
        // through acpmux and the app opens the fork at the destination.
        if let view = context.services.agentTabs.existingView(tab.id) {
            guard !context.services.agentTabs.isNewTabPage(tab.id) else { throw ActionFailure(message: MiscHandlerStrings.noForkTarget) }
            view.forkConversation(to: destination, offerDestinations: offerDestinations)
            return
        }
        guard tab.kind == .pty else { throw ActionFailure(message: MiscHandlerStrings.noForkTarget) }
        // The terminal's agent forks by its own CLI, or through acpmux when its CLI has none (Muse).
        let route = terminalFork(tab.agent)
        let environment: AcpmuxEnvironment?
        switch route {
        case .noSession: throw ActionFailure(message: MiscHandlerStrings.noAgentSession)
        case .unsupported: throw ActionFailure(message: MiscHandlerStrings.forkTerminalAgents)
        case .command: environment = nil
        case .acp:
            guard let own = QuitAgents.environment(context.services) else { throw ActionFailure(message: MiscHandlerStrings.forkTerminalAgents) }
            environment = own
        }
        let connection = try context.requireConnection()
        let handle = pane.pane.handle
        let options = SpawnOptions(cwd: tab.cwd, workspace: context.services.workspaceKey(of: pane.pane))
        let cwd = tab.cwd
        // A new row is as tall as the agent's row (New Row's G3 rule).
        let rowHeight = pane.workspace?.layoutModel.newRowHeight(below: pane.layoutPaneID) ?? 1000
        let logger = context.daemon.logger
        let refusals = context.services.refusalHUD
        let windows = context.services.windows
        let repair = context.services.emptyWorkspaces
        // A fork into a new workspace is placed like Cmd-N: in the current group (cx-caoh).
        let key = WorkspaceKey.generate()
        if destination == .workspace || destination == .window {
            let windows = context.services.windows
            NewWorkspacePlacements.expect(key.rawValue, in: nil, byDefault: NewWorkspacePlacements.rule(for: nil, in: windows), windows: windows)
        }
        Task {
            do {
                // The shell line first: an acpmux fork that fails opens no empty terminal.
                let line: String
                switch route {
                case let .command(command): line = command + "\n"
                case let .acp(harness, session):
                    guard let environment else { return }
                    let forked = try await environment.forkChat(harness: harness, agentSessionId: session, cwd: cwd)
                    guard let resume = TerminalAgentFork.resumeLine(harness: harness, session: forked) else { return }
                    line = resume + "\n"
                case .noSession, .unsupported: return
                }
                let surface: SurfaceID?
                var workspace: WorkspaceKey?
                switch TerminalForkPlacement(destination) {
                case let .split(down, swap):
                    surface = try await connection.split(handle, direction: down ? .down : .right, options: options).surface
                    // A split always opens right/below; swap to put the fork first.
                    if swap { try await connection.swapPane(handle, with: .direction(down ? .down : .right)) }
                case let .column(left):
                    surface = try await connection.newColumn(beside: handle, left: left, options: options).surface
                case .row:
                    surface = try await RowCommands(connection).newRow(below: handle, height: rowHeight, options: options).surface
                case .tab:
                    surface = try await connection.newTab(in: handle, options: options).surface
                case .workspace:
                    workspace = key
                    surface = try await WorkspaceCreation.create(key, name: nil, on: connection, repair: repair) { created in
                        try await WorkspaceCreation.firstTerminal(in: created, cwd: options.cwd, on: connection).surface
                    }
                }
                if let surface { try await connection.send(surface, text: line) }
                if let workspace {
                    context.window(showing: workspace.rawValue)
                    // A new window: the fork's new workspace moves there, as Move Workspace to New Window moves one.
                    if destination == .window {
                        _ = context.registry.perform("moveWorkspaceToNewWindow", invocation: ActionInvocation(target: ActionTargetRef(kind: .workspace, id: workspace.rawValue), origin: .user))
                    }
                }
            } catch {
                logger.error("fork-agent-conversation failed: \(String(describing: error), privacy: .public)")
                // The person asked for a fork: say why there is none (acpmux's reason). A pane still opening was shown
                // already where the request was refused (`DaemonConnection.observePaneNotReady`), once.
                if (error as? PaneNotReady)?.shown != true {
                    refusals.show(error is PaneNotReady ? MiscHandlerStrings.paneNotReady : error.localizedDescription, in: windows.active?.window)
                }
            }
        }
    }

    /// Open File: the agent pane's changed files, the palette and `cmux file open`.
    /// The file is checked first (`AgentPaneFileOpening`); a tab opens in the
    /// invocation's pane, else the focused one.
    private static func openFile(_ invocation: ActionInvocation, context: AppActionContext) throws {
        let path = invocation["path"]?.stringValue ?? ""
        // No path (the File menu, a shortcut, `cmux file open`): the cmux picker (R89).
        guard !path.isEmpty else { return try ViewerHandlers.openFilePicker(invocation, context: context) }
        // The palette and the control socket accept only the catalog's choices;
        // an in-app caller that passes another place is refused, not ignored.
        let place = invocation["where"]?.stringValue ?? AgentPaneFileTarget.tab.rawValue
        guard let target = AgentPaneFileTarget(rawValue: place) else { throw ActionFailure(message: MiscHandlerStrings.invalidPlace(place)) }
        // A path named in a Cloud pane belongs to that machine, so a local editor is refused there. The
        // editor needs no pane: with none named or focused (no window open), the file is this Mac's.
        let paneless = target == .editor && !context.namesPane(invocation) && context.services.windows.active?.focusedPane == nil
        let pane = paneless ? nil : context.paneController(invocation)
        guard paneless || pane != nil else { return }
        // Open as Text applies on the file's machine, including Cloud Markdown.
        let asText = invocation["asText"]?.boolValue ?? (invocation["asText"]?.stringValue == "true")
        if let pane, !pane.daemon.isLocal {
            guard path.hasPrefix("/"), !path.contains("\u{0}") else { throw ActionFailure(message: MiscHandlerStrings.pathNotAbsolute(path)) }
            let url = URL(fileURLWithPath: path)
            guard target == .tab else { throw ActionFailure(message: RemoteFilePageFiles.remotePreview(url.lastPathComponent)) }
            if let reason = context.services.viewers.openFile(url, on: pane.daemon, in: pane, userChose: invocation.origin == .user, asText: asText) {
                throw ActionFailure(message: reason)
            }
            return
        }
        // A tab is the file pages (diff-host S6, S7) or, for HTML and SVG, a browser tab that
        // renders the page (u18051); Open as Text and Edit Source show its source.
        if target == .tab, let pane {
            guard path.hasPrefix("/") else { throw ActionFailure(message: MiscHandlerStrings.pathNotAbsolute(path)) }
            guard let url = AgentPaneFileOpen.resolve(path) else { throw ActionFailure(message: MiscHandlerStrings.fileNotFound(path)) }
            // `cmux open` run from an agent chat: a quote from the file's viewer goes back to that chat.
            if let session = invocation.callerAgentSession, let chat = context.services.agentTabs.tab(showing: session) {
                context.services.chatQuoteOpeners.noteOpened(url, byAgentTab: chat)
            }
            if let reason = context.services.viewers.openFile(url, in: pane, userChose: invocation.origin == .user, asText: asText) { throw ActionFailure(message: reason) }
            return
        }
        let opening: AgentPaneFileOpening
        do {
            opening = try AgentPaneFileOpening.plan(path: path, target: target, editor: { context.services.editorApps.application() })
        } catch AgentPaneFileRefusal.relativePath {
            throw ActionFailure(message: MiscHandlerStrings.pathNotAbsolute(path))
        } catch AgentPaneFileRefusal.notInTab {
            throw ActionFailure(message: MiscHandlerStrings.fileNotInTab(path))
        } catch AgentPaneFileRefusal.noEditor {
            throw ActionFailure(message: MiscHandlerStrings.noEditor)
        } catch {
            throw ActionFailure(message: MiscHandlerStrings.fileNotFound(path))
        }
        if let editor = opening.editor {
            context.services.editorApps.open(opening.url, withApplicationAt: editor)
        }
    }
}
