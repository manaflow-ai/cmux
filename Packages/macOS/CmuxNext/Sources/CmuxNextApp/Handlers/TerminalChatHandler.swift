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
        // No longer answered (a chat mid-turn resumes in a terminal that waits for the turn); kept for decoding.
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

    /// Toggle Terminal and Chat's facts about `tab`, which the action and the tab's right-click row (``offersToggle(on:services:)``)
    /// both hand to the Rust route, so the row shows exactly where the key acts; with the chat's adopted session
    /// (`key`, `harness:agentSessionId`) and the live terminals running it, best first (as an `agent/` link picks them).
    /// `membership`: only what decides whether the route refuses the tab (the tab's kind and its session), for the
    /// right-click row: the running terminals, the turn and the hand-off only pick
    /// among the routes that act, and reading them there would observe every machine's agents.
    static func facts(_ tab: TabModel, services: AppServices, membership: Bool = false)
        -> (facts: WindowRules.ToggleFacts, key: String?, terminals: [String]) {
        let tabs = services.agentTabs, terminal = tab.kind == .pty
        // A terminal's session is its agent's report (a hook's `agent_session_id`); a chat's, the outside session it adopted,
        // else (a chat started here) its own acpmux run under its harness: `acpmux resume-here` finds the conversation from it.
        let own = terminal ? nil : tab.agentSession.flatMap { ref in
            ref.harness.flatMap { harness in tabs.session(of: tab.id).map { AgentPaneAdopt(harness: harness, agentSessionId: $0) } }
        }
        let adopted = terminal ? nil : tabs.adoption(of: tab.id) ?? own, key = adopted.map { "\($0.harness):\($0.agentSessionId)" }
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

    /// Whether `tab` is half of a terminal and chat pair, so Toggle Terminal and Chat acts on it; false when the route
    /// refuses it (not a terminal or chat, no session, a harness acpmux cannot resume). The tab's right-click offers the
    /// action only then (``PaneController/contextMenu(for:)``).
    static func offersToggle(on tab: TabModel, services: AppServices) -> Bool {
        offersToggle(WindowRules().terminalChatToggle(facts(tab, services: services, membership: true).facts))
    }

    /// Whether the route's answer `route` acts: every answer but a refusal.
    static func offersToggle(_ route: WindowRules.TerminalChatToggle?) -> Bool {
        switch route {
        case .notAgentTab?, .noSession?, .unsupportedHarness?, nil: false
        case .toChat?, .toTerminal?, .resumeInTerminal?, .handingOff?, .busy?: true
        }
    }

    /// Whether chat `ref` has a turn open: working, or waiting on a permission or a question.
    private static func turnOpen(_ ref: AgentSessionRef) -> Bool {
        let store = AgentTurnStateStore.shared
        return store.state(for: ref) == .needsInput || store.isWorking(ref, isChatMachine: { _ in false })
    }

    /// A chat no terminal runs, mid-turn or not: a new terminal beside it shows at once and runs
    /// `acpmux resume-here <run>` (cmux-tui `acpmux/src/cli/resume_here.rs`). That command shows the
    /// running turn, waits for it to end (never cut off), then acpmux turns this same chat into a View
    /// Only watch of the conversation (`_acpmux/release_to_watch`) and the terminal runs the harness's
    /// resume command. The chat tab stays where it is, with its history and scroll: no tab is replaced
    /// and nothing reloads (Leo, 2026-11-12: two live views of one session, instant both ways, mid-turn).
    private static func resume(harness: String, session: String, chat: (pane: PaneController, id: StripTabID), tab: TabModel,
                               services: AppServices) throws -> ActionEffect {
        let tabs = services.agentTabs, key = "\(harness):\(session)"
        guard let acpmux = QuitAgents.environment(services), let run = tabs.session(of: tab.id) else {
            throw ActionFailure(message: MiscHandlerStrings.terminalChatStopFailed)
        }
        let cwd = tabs.existingView(tab.id)?.model.transport.sessions.folder(of: run) ?? tab.cwd
        let target = chat.pane
        // Until the terminal's hooks report the session, a second Toggle shows it instead of resuming again.
        tabs.terminalHandOffs[key] = WindowRules.HandOff(deadline: Date().timeIntervalSince1970 + 60)
        let work = services.registry.capturingWork {
            // A `then` replaces Home's dock placement, so it places the tab too.
            target.newTerminalTab(cwd: cwd, typing: resumeHere(acpmux, run: run) + "\r",
                                  placementOwner: HomeDockOpens.opensBeside(target.pane, services: services),
                                  then: HomeDockOpens.placing(target.pane, services: services, focus: true, then: { surface in
                if let made = target.daemon.store.tab(surface: surface) { tabs.terminalHandOffs[key]?.tab = made.id }
            }))
        }
        if work.isEmpty { tabs.terminalHandOffs[key] = nil; throw ActionFailure(message: MiscHandlerStrings.terminalChatNoPane) }
        return .applied(result: {
            for task in work { if let failure = await task.value { tabs.terminalHandOffs[key] = nil; return .failure(failure) } }
            return .success([:])
        })
    }

    /// The line the hand-off's terminal runs: this app's acpmux, on this app's daemon, resuming chat `run` here.
    static func resumeHere(_ acpmux: AcpmuxEnvironment, run: String) -> String {
        let quote = AgentResume.shellQuoted
        let env = ["ACPMUX_HOME": acpmux.home.path, "ACPMUX_SOCKET": acpmux.socketPath].map { "\($0.key)=\(quote($0.value))" }.sorted()
        return (env + [quote(acpmux.executable.path), "resume-here", quote(run)]).joined(separator: " ")
    }
}
