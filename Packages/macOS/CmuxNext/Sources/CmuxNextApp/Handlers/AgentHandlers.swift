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
            if let pane = context.scope(invocation).pane {
                openNewAgentChat(in: pane, invocation: invocation, context: context)
                return
            }
            // Cmd-I is also the entry point while a workspace is settling and
            // has no mounted pane yet. Reuse Cmd-T's shared path to repair or
            // create the active workspace's first usable pane, then wait for
            // its controller before opening the agent tab. Explicit targets
            // still fail normally instead of silently switching panes.
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
                openNewAgentChat(in: pane, invocation: invocation, context: context)
                return nil
            })
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
        // Cmd-K in an agent chat: the page's "Search chats" palette over its sessions.
        registry.bind("agentPane.searchChats", run: { invocation in
            guard let pane = context.scope(invocation).pane, let key = pane.currentTabKey,
                  let view = context.services.agentTabs.existingView(key) else {
                return context.refuse(MiscHandlerStrings.noAgentChat)
            }
            view.showSearchChats()
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

    @MainActor
    private static func waitForPaneController(in workspace: WorkspaceModel, context: AppActionContext) async -> PaneController? {
        for await paneID in Observations({ workspace.screens.flatMap(\.panes).first?.id }) {
            guard let paneID, let pane = workspace.screens.flatMap(\.panes).first(where: { $0.id == paneID }) else { continue }
            for await mounted in Observations({ context.services.paneController(for: pane) != nil }) where mounted {
                return context.services.paneController(for: pane)
            }
        }
        return nil
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
        guard !path.isEmpty else { return ViewerHandlers.openFilePicker(invocation, context: context) }
        // The palette and the control socket accept only the catalog's choices;
        // an in-app caller that passes another place is refused, not ignored.
        let place = invocation["where"]?.stringValue ?? AgentPaneFileTarget.tab.rawValue
        guard let target = AgentPaneFileTarget(rawValue: place) else { throw ActionFailure(message: MiscHandlerStrings.invalidPlace(place)) }
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
        } else if let pane = context.paneController(invocation) {
            pane.newBrowserTab(url: opening.url)
        }
    }

    private static func openPrivacyPane(_ anchor: String, _ context: AppActionContext) throws {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        try context.open(url)
    }
}
