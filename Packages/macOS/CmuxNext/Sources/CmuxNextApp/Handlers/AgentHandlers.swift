import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextControl
import CmuxNextDaemon
import Observation

/// Agent actions. Forks read the agent session the daemon reports for the
/// focused terminal (`TabModel.agent`, from `list-agents` state) and start
/// `claude --resume <session> --fork-session` in a new terminal placed by
/// daemon commands. New Agent Chat opens the React acpmux pane in a tab
/// (CmuxNextAgentPane), and Toggle Dictation drives its composer's mic.
/// Quick Agent Chat toggles the floating `QuickComposerController` panel.
/// Terminal-as-chat, Teams, and Computer Use are
/// typed-unavailable.
enum AgentHandlers {
    enum Placement {
        case right, left, above, below, newTab, newWorkspace
    }

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let forks: [(ActionID, Placement)] = [
            ("palette.forkAgentConversationRight", .right), ("palette.forkAgentConversationLeft", .left),
            ("palette.forkAgentConversationTop", .above), ("palette.forkAgentConversationBottom", .below),
            ("palette.forkAgentConversationNewTab", .newTab), ("palette.forkAgentConversationNewWorkspace", .newWorkspace),
        ]
        for (id, placement) in forks {
            registry.bind(id, run: { try fork(placement, invocation: $0, context: context) })
        }
        registry.bind("agentActivity.open", run: { _ in context.services.agentActivityPage.open() })
        AgentSessionWorkspace.bind(into: registry, context: context)
        ChiefInspectorHandlers.bind(into: registry, context: context)
        AddHarnessHandler.bind(into: registry, context: context)
        registry.bind("home.toggleChiefSettings", run: { _ in
            NotificationCenter.default.post(name: HomeHostView.toggleSettings, object: nil)
        })
        // Quick Agent Chat: the global hot key, palette, menu and CLI toggle one floating panel.
        // The panel takes the keyboard from the frontmost app, so automation
        // cannot open it unless it asks for focus.
        registry.bind("palette.quickAgentChat", run: { invocation in
            guard invocation.allowsViewChange else { return context.refuse(MiscHandlerStrings.quickChatNeedsFocus) }
            guard context.services.agentTabs.canHostChat else { return context.refuse(MiscHandlerStrings.quickChatUnavailable) }
            context.services.quickComposer.toggle()
        })
        registry.bind("palette.computerUse.accessibility", run: { _ in try openPrivacyPane("Privacy_Accessibility", context) })
        registry.bind("palette.computerUse.screenRecording", run: { _ in try openPrivacyPane("Privacy_ScreenCapture", context) })
        registry.bindAgentPane { invocation in
            if let pane = context.scope(invocation).pane,
               openNewAgentChatWorkspace(from: pane, invocation: invocation, context: context) { return }
            withAgentPane(invocation, context: context) { pane in
                openNewAgentChat(in: pane, invocation: invocation, context: context)
            }
        }
        registry.bind(.fileOpen, run: { try openFile($0, context: context) })
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
                view.runPermissionAction(command)
            })
        }
        // Continue in… is a user-facing chooser. Headless callers use the
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
        registry.bindUnavailable(["palette.openTerminalChatView"], ActionFailure(message: MiscHandlerStrings.agentChat))
        registry.bindUnavailable(["palette.launchClaudeTeams", "palette.launchCodexTeams"], ActionFailure(message: MiscHandlerStrings.agentTeams))
        registry.bindUnavailable(
            ["palette.computerUse.setup", "computerUseFocus", "computerUseFocusCallingTerminal", "computerUseStop"],
            ActionFailure(message: MiscHandlerStrings.computerUse)
        )
    }

    /// The pane a new agent chat opens in (New Agent Chat, Add Harness…): the invocation's pane,
    /// else, while the active workspace has no mounted pane yet (Home, a settling workspace),
    /// Cmd-T's shared path repairs or creates its first usable pane and `open` runs once its
    /// controller mounts. Explicit targets still fail normally instead of switching panes.
    static func withAgentPane(_ invocation: ActionInvocation, context: AppActionContext,
                              _ open: @escaping @MainActor (PaneController) -> Void) {
        if let pane = context.scope(invocation).pane { return open(pane) }
        guard invocation.target == nil else { return context.refuse(MiscHandlerStrings.noPane) }
        guard let workspace = context.scope(invocation).workspace else { return context.refuse(MiscHandlerStrings.noPane) }
        _ = context.registry.perform("newTab.sameKind", invocation: invocation)
        context.registry.track(Task { @MainActor in
            let pane = try? await ControlDeadline.shared.run(
                method: "agent-pane.mount",
                deadline: .now + .seconds(10)
            ) { @MainActor in
                await Self.waitForPaneController(in: workspace, context: context)
            }
            guard let pane else {
                context.refuse(MiscHandlerStrings.noPane)
                return ActionWorkFailure(MiscHandlerStrings.noPane)
            }
            open(pane)
            return nil
        })
    }

    @MainActor
    private static func waitForPaneController(in workspace: WorkspaceModel, context: AppActionContext) async -> PaneController? {
        // The store's panes are observable; mounted controllers are not, so
        // the mount generation stands in for them (`PaneMounts`).
        let services = context.services
        func mounted() -> PaneController? {
            workspace.screens.flatMap(\.panes).lazy.compactMap(services.paneController(for:)).first
        }
        for await isMounted in Observations({ () -> Bool in
            _ = services.paneMounts.generation
            return mounted() != nil
        }) where isMounted {
            return mounted()
        }
        return nil
    }

    /// A person's New Agent Chat (Cmd-I, the menu, the palette) opens a new
    /// workspace whose only tab is the chat, like a new thread in the Codex
    /// and Claude apps (lawrence-call-1006 D). The chat inherits the focused
    /// tab's cwd and draft as a tab would. Scripts, an explicit target and a
    /// daemon that cannot hold a chat get a tab in `pane`: false.
    private static func openNewAgentChatWorkspace(from pane: PaneController, invocation: ActionInvocation,
                                                  context: AppActionContext) -> Bool {
        let services = context.services
        guard invocation.origin == .user, invocation.target == nil, services.agentTabs.canHost(on: pane.daemon),
              let windowID = context.activeWindow?.state.id else { return false }
        let folder = pane.selectedTab?.cwd
        services.newTabKinds.record(.agent, folder: folder)
        let source = pane.agentSeedFromSelectedTab()
        let daemon = pane.daemon
        context.registry.track(Task { @MainActor in
            var seed = await source?.take() ?? AgentPaneSeed()
            seed.cwd = seed.cwd ?? folder
            var spawn = WorkspaceSpawn(cwd: seed.cwd)
            spawn.firstChat = seed
            do {
                _ = try await services.windows.createWorkspace(spawn, on: daemon, into: windowID)
                return nil
            } catch {
                daemon.logger.error("new agent chat workspace failed: \(String(describing: error), privacy: .public)")
                return ActionWorkFailure("new agent chat: \(error)")
            }
        })
        return true
    }

    private static func openNewAgentChat(in pane: PaneController, invocation: ActionInvocation, context: AppActionContext) {
        if invocation.origin == .user { context.services.newTabKinds.record(.agent, folder: pane.selectedTab?.cwd) }
        pane.newAgentTab()
    }

    /// The shell line that forks `session`, or nil for agents without fork
    /// support or session ids that are not plain tokens.
    static func forkCommand(agent: String?, session: String?) -> String? {
        guard agent?.lowercased().contains("claude") == true, let session, !session.isEmpty,
              session.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return "claude --resume \(session) --fork-session"
    }

    private static func fork(_ placement: Placement, invocation: ActionInvocation, context: AppActionContext) throws {
        guard let (pane, id) = context.scope(invocation).tab, let tab = pane.tab(id), tab.kind == .pty else {
            throw ActionFailure(message: MiscHandlerStrings.noTerminal)
        }
        guard let status = tab.agent, status.session?.isEmpty == false else { throw ActionFailure(message: MiscHandlerStrings.noAgentSession) }
        guard let command = forkCommand(agent: status.agent, session: status.session) else {
            throw ActionFailure(message: MiscHandlerStrings.forkClaudeOnly)
        }
        let connection = try context.requireConnection()
        let handle = pane.pane.handle
        let options = SpawnOptions(cwd: tab.cwd, workspace: context.services.workspaceKey(of: pane.pane))
        let line = command + "\n"
        let logger = context.daemon.logger
        let repair = context.services.emptyWorkspaces!
        Task {
            do {
                let surface: SurfaceID?
                var workspace: WorkspaceKey?
                switch placement {
                case .right, .left:
                    surface = try await connection.split(handle, direction: .right, options: options).surface
                    // A split always opens right/below; swap to put the fork first.
                    if placement == .left { try await connection.swapPane(handle, with: .direction(.right)) }
                case .below, .above:
                    surface = try await connection.split(handle, direction: .down, options: options).surface
                    if placement == .above { try await connection.swapPane(handle, with: .direction(.down)) }
                case .newTab:
                    surface = try await connection.newTab(in: handle, options: options).surface
                case .newWorkspace:
                    let key = WorkspaceKey.generate()
                    workspace = key
                    surface = try await WorkspaceCreation.create(key, name: nil, on: connection, repair: repair) { created in
                        try await connection.createTerminal(in: created, cwd: options.cwd).surface
                    }
                }
                if let surface { try await connection.send(surface, text: line) }
                if let workspace { context.window(showing: workspace.rawValue) }
            } catch {
                logger.error("fork-agent-conversation failed: \(String(describing: error), privacy: .public)")
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
        // A tab is the file pages (diff-host S6, S7): any regular file shows there as text (never
        // run), so the tab check for WebKit page types no longer applies.
        if target == .tab {
            guard path.hasPrefix("/") else { throw ActionFailure(message: MiscHandlerStrings.pathNotAbsolute(path)) }
            guard let url = AgentPaneFileOpen.resolve(path) else { throw ActionFailure(message: MiscHandlerStrings.fileNotFound(path)) }
            guard let pane = context.paneController(invocation) else { return }
            let opener = context.services.viewers.fileOpener
            let reason = (opener as? FilePageOpener)?.open(url, in: pane, userChose: invocation.origin == .user) ?? opener.open(url, in: pane)
            if let reason { throw ActionFailure(message: reason) }
            return
        }
        let opening: AgentPaneFileOpening
        do {
            opening = try AgentPaneFileOpening.plan(path: path, target: target)
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
            NSWorkspace.shared.open([opening.url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private static func openPrivacyPane(_ anchor: String, _ context: AppActionContext) throws {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        try context.open(url)
    }
}
