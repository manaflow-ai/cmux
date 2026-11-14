import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextHistory
import CmuxNextTabs
import CmuxNextWindowRules
import Foundation

/// Open Terminal as Chat (`palette.openTerminalChatView`; the palette and `cmux agent
/// open-terminal-as-chat`, so MCP's action run too): the Claude Code or Codex session the focused
/// terminal runs (`TabModel.agent`, from the daemon's agent state) opens as an agent chat tab
/// beside the terminal, resuming the same session over ACP (acpmux adopt, as Open Chat and the
/// classic import resume an outside chat). The terminal stays open: closing it would end the
/// running agent. A tab that already resumes the session is shown instead of a second one.
/// Toggle Terminal and Chat (`palette.toggleTerminalChat`) does that from the terminal (View Only:
/// the terminal keeps running it), and from the chat shows the terminal running the session it
/// resumes, else resumes the session in a new terminal in the chat's place: one action flips the two views.
enum TerminalChatHandler {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bindEffect("palette.openTerminalChatView", requires: nil, effect: { try open($0, context: context) })
        registry.bindEffect("palette.toggleTerminalChat", requires: nil, effect: { try toggle($0, context: context, watches: true) })
    }

    private static func open(_ invocation: ActionInvocation, context: AppActionContext) throws -> ActionEffect {
        guard let (pane, id) = context.scope(invocation).tab, let tab = pane.tab(id), tab.kind == .pty else {
            throw ActionFailure(message: MiscHandlerStrings.noTerminal)
        }
        return try toggle(invocation, context: context)
    }

    private static func toggle(_ invocation: ActionInvocation, context: AppActionContext, watches: Bool = false) throws -> ActionEffect {
        guard let (pane, id) = context.scope(invocation).tab, let tab = pane.tab(id) else {
            throw ActionFailure(message: MiscHandlerStrings.terminalChatNotAgentTab)
        }
        let services = context.services, tabs = services.agentTabs, terminal = tab.kind == .pty
        let read = facts(tab, services: services), key = read.key, terminals = read.terminals
        // The route is Rust's (cmux-window-rules `tabs::terminal_chat_toggle`).
        switch WindowRules().terminalChatToggle(read.facts) {
        case .notAgentTab?, nil: throw ActionFailure(message: MiscHandlerStrings.terminalChatNotAgentTab)
        case .noSession?: throw ActionFailure(message: terminal ? MiscHandlerStrings.terminalChatNoSession : MiscHandlerStrings.terminalChatNoTerminal)
        case .unsupportedHarness?: throw ActionFailure(message: MiscHandlerStrings.terminalChatHarness)
        case .busy?: throw ActionFailure(message: MiscHandlerStrings.terminalChatBusy)
        case .handingOff(let made)?:
            // An earlier Toggle is resuming the session: its terminal shows, and nothing resumes it twice.
            if let made, invocation.allowsViewChange { _ = services.revealTab(made) }
            return .done
        case .resumeInTerminal(let harness, let session)?:
            return try resume(harness: harness, session: session, chat: (pane, id), tab: tab, services: services)
        case .toTerminal?:
            if let key { tabs.terminalHandOffs[key] = nil } // a terminal reports the session: any hand-off is over
            // Showing it is a view change; a headless run leaves the user's focus alone.
            guard !invocation.allowsViewChange || terminals.contains(where: { services.revealTab($0) }) else {
                throw ActionFailure(message: MiscHandlerStrings.terminalChatNoTerminal)
            }
            return .done
        case .toChat(let harness, let session)?:
            tabs.terminalHandOffs["\(harness):\(session)"] = nil // the terminal reports the session
            let adopt = AgentPaneAdopt(harness: harness, agentSessionId: session, watch: watches ? true : nil)
            // A tab that already resumes this session is shown instead of a duplicate.
            if let existing = services.agentTabs.tab(resuming: adopt) {
                if invocation.allowsViewChange { _ = services.revealTab(existing) }
                return .done
            }
            let seed = AgentPaneSeedSource(AgentPaneSeed(cwd: tab.cwd, adopt: adopt))
            let pending: AgentTabPending
            do {
                pending = try services.agentTabs.open(in: pane.pane.handle, of: pane.daemon, seed: seed, adopt: adopt)
            } catch let refusal as AgentTabRefusal {
                throw ActionFailure(message: refusal.message)
            }
            // The new tab shows now; the registry reports a failed open.
            pane.selectWhenReported(surface: pending.surface)
            return .applied(result: {
                do { _ = try await pending.value(); return .success([:]) } catch is CancellationError {
                    return .success([:]) // the person closed the tab first
                } catch { return .failure(ActionWorkFailure("open terminal as chat", error)) }
            })
        }
    }

    /// Toggle Terminal and Chat's facts about `tab`, which the action and the pane toolbar's toggle (``PaneToolbar``)
    /// both hand to the Rust route, so the control shows exactly where the key acts; with the chat's adopted session
    /// (`key`, `harness:agentSessionId`) and the live terminals running it, best first (as an `agent/` link picks them).
    /// `membership`: only what decides whether the route refuses the tab (the tab's kind and its session), for the
    /// toolbar, which asks for every tab of every pane: the running terminals, the turn and the hand-off only pick
    /// among the routes that act, and reading them there would observe every machine's agents.
    static func facts(_ tab: TabModel, services: AppServices, membership: Bool = false)
        -> (facts: WindowRules.ToggleFacts, key: String?, terminals: [String]) {
        let tabs = services.agentTabs, terminal = tab.kind == .pty
        // A terminal's session is its agent's report (a hook's `agent_session_id`); a chat's, the outside session it adopted.
        let adopted = terminal ? nil : tabs.adoption(of: tab.id), key = adopted.map { "\($0.harness):\($0.agentSessionId)" }
        var facts = WindowRules.ToggleFacts(terminal: terminal, chat: !terminal && tabs.isAgentTab(tab.id),
                                            agent: terminal ? tab.agent?.agent : adopted?.harness,
                                            session: terminal ? tab.agent?.harnessSessionID : adopted?.agentSessionId)
        guard !membership, let adopted else { return (facts, key, []) }
        let terminals = DeepLink.agentTabs(harness: adopted.harness, session: adopted.agentSessionId, adopted: nil,
                                           harnessSessions: services.machines.daemons.flatMap(\.store.reachableAgentHarnessSessions).filter { $0.tab != tab.id })
        let handOff = key.flatMap { tabs.terminalHandOffs[$0] }
        facts.running = !terminals.isEmpty
        facts.busy = tab.agentSession.map(turnOpen) ?? false
        facts.handOff = handOff
        facts.handOffOpen = handOff?.tab.map { services.locateTabOnAnyMachine($0) != nil } ?? false
        facts.now = Date().timeIntervalSince1970
        return (facts, key, terminals)
    }

    /// The face of a terminal and chat pair `tab` is, nil when the route refuses it (not a terminal or chat,
    /// no session, a harness acpmux cannot resume): the pane toolbar's toggle shows only on a pair.
    static func face(of tab: TabModel, services: AppServices) -> PaneTerminalChatFace? {
        let read = facts(tab, services: services, membership: true).facts
        return face(WindowRules().terminalChatToggle(read), terminal: read.terminal)
    }

    /// The face the route's answer `route` shows for a terminal (`terminal`) or a chat: none for a refusal.
    static func face(_ route: WindowRules.TerminalChatToggle?, terminal: Bool) -> PaneTerminalChatFace? {
        switch route {
        case .notAgentTab?, .noSession?, .unsupportedHarness?, nil: nil
        case .toChat?, .toTerminal?, .resumeInTerminal?, .handingOff?, .busy?: terminal ? .terminal : .chat
        }
    }

    /// Whether chat `ref` has a turn open: working, or waiting on a permission or a question.
    private static func turnOpen(_ ref: AgentSessionRef) -> Bool {
        let store = AgentTurnStateStore.shared
        return store.state(for: ref) == .needsInput || store.isWorking(ref, isChatMachine: { _ in false })
    }

    /// A chat no terminal runs: its acpmux run stops (the transcript kept), the harness's resume
    /// command opens the session in a new terminal beside it, and the stopped chat gives way to a
    /// View Only chat of the session the terminal now runs (``watchChat``), so the pair stays and
    /// Toggle goes back and forth both ways (Leo, 2026-11-12: "that's the whole joy of the thing").
    private static func resume(harness: String, session: String, chat: (pane: PaneController, id: StripTabID), tab: TabModel,
                               services: AppServices) throws -> ActionEffect {
        let tabs = services.agentTabs, key = "\(harness):\(session)"
        guard let command = AgentResume.command(provider: harness, sessionID: session), let acpmux = QuitAgents.environment(services),
              let run = tabs.session(of: tab.id) else { throw ActionFailure(message: MiscHandlerStrings.terminalChatStopFailed) }
        let cwd = tabs.existingView(tab.id)?.model.transport.sessions.folder(of: run) ?? tab.cwd
        let workspace = chat.pane.daemon.store.workspace(containing: chat.pane.pane.handle)?.id
        // Until the terminal's hooks report the session, a second Toggle shows it instead of resuming again.
        tabs.terminalHandOffs[key] = WindowRules.HandOff(deadline: Date().timeIntervalSince1970 + 60)
        // action-wait-allow: acpmux must end the chat's run before the harness resumes its session; nothing can show first
        return .waiting(.externalProcess) {
            @MainActor func fail(_ reason: String) -> ActionWorkFailure {
                tabs.terminalHandOffs[key] = nil
                return ActionWorkFailure(refusal: .unavailable, reason: reason)
            }
            // A prompt sent since the click is a turn too: it is never cut off.
            if tab.agentSession.map(turnOpen) == true { return fail(MiscHandlerStrings.terminalChatBusy) }
            do { try await acpmux.stopSession(id: run) } catch { return fail(MiscHandlerStrings.terminalChatStopFailed) }
            // The chat's pane, else its workspace's focused one when the pane closed meanwhile.
            guard let target = services.paneController(for: chat.pane.pane)
                ?? workspace.flatMap({ services.windows.reveal(workspaceID: $0)?.focusedPane }) else { return fail(MiscHandlerStrings.terminalChatNoPane) }
            let work = services.registry.capturingWork {
                // A `then` replaces Home's dock placement, so it places the tab too.
                target.newTerminalTab(cwd: cwd, typing: command + "\r", placementOwner: HomeDockOpens.opensBeside(target.pane, services: services),
                                      then: HomeDockOpens.placing(target.pane, services: services, focus: true, then: { surface in
                    // The terminal stands for the session now; the stopped chat closes and no longer resumes it.
                    let made = target.daemon.store.tab(surface: surface)
                    if let made { tabs.terminalHandOffs[key]?.tab = made.id }
                    tabs.adoptions[key] = nil
                    services.paneController(for: chat.pane.pane)?.close([chat.id])
                    watchChat(harness: harness, session: session, cwd: cwd, in: target, after: made, services: services)
                }))
            }
            for task in work { if let failure = await task.value { tabs.terminalHandOffs[key] = nil; return failure } }
            return work.isEmpty ? fail(MiscHandlerStrings.terminalChatNoPane) : nil
        }
    }

    /// The chat half of the pair once a hand-off's terminal exists: a View Only chat (acpmux `watch`) of the
    /// session it runs, right after it in its pane, left unselected (the terminal shows). acpmux's run of
    /// the old chat stopped, so a page cannot take it back in place: this one tab loads the transcript once,
    /// and every swap after it is a selection of the two parked views.
    private static func watchChat(harness: String, session: String, cwd: String?, in pane: PaneController, after terminal: TabModel?,
                                  services: AppServices) {
        let adopt = AgentPaneAdopt(harness: harness, agentSessionId: session, watch: true)
        let place = NewTabSlot.placing(after: terminal, services: services, then: Optional<@MainActor (String) -> Void>.none)
        let pending: AgentTabPending
        do {
            pending = try services.agentTabs.open(in: pane.pane.handle, of: pane.daemon,
                                                  seed: AgentPaneSeedSource(AgentPaneSeed(cwd: cwd, adopt: adopt)), adopt: adopt)
        } catch {
            // The terminal runs the session either way; a later Toggle from it opens the chat.
            services.registry.refuse((error as? AgentTabRefusal)?.message ?? String(describing: error))
            return
        }
        services.registry.trackOrRefuse(Task { @MainActor in
            do { place?(try await pending.value().key); return nil } catch is CancellationError {
                return nil // the person closed the tab first
            } catch { return ActionWorkFailure("open terminal as chat", error) }
        })
    }
}
