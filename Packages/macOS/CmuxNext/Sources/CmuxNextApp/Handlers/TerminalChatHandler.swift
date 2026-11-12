import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextWindowRules

/// Open Terminal as Chat (`palette.openTerminalChatView`; the palette and `cmux agent
/// open-terminal-as-chat`, so MCP's action run too): the Claude Code or Codex session the focused
/// terminal runs (`TabModel.agent`, from the daemon's agent state) opens as an agent chat tab
/// beside the terminal, resuming the same session over ACP (acpmux adopt, as Open Chat and the
/// classic import resume an outside chat). The terminal stays open: closing it would end the
/// running agent. A tab that already resumes the session is shown instead of a second one.
/// Toggle Terminal and Chat (`palette.toggleTerminalChat`) does that from the terminal, and from
/// the chat shows the terminal running the session it resumes: one action flips the two views.
enum TerminalChatHandler {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bindEffect("palette.openTerminalChatView", requires: nil, effect: { try open($0, context: context) })
        registry.bindEffect("palette.toggleTerminalChat", requires: nil, effect: { try toggle($0, context: context) })
    }

    private static func open(_ invocation: ActionInvocation, context: AppActionContext) throws -> ActionEffect {
        guard let (pane, id) = context.scope(invocation).tab, let tab = pane.tab(id), tab.kind == .pty else {
            throw ActionFailure(message: MiscHandlerStrings.noTerminal)
        }
        return try toggle(invocation, context: context)
    }

    private static func toggle(_ invocation: ActionInvocation, context: AppActionContext) throws -> ActionEffect {
        guard let (pane, id) = context.scope(invocation).tab, let tab = pane.tab(id) else {
            throw ActionFailure(message: MiscHandlerStrings.terminalChatNotAgentTab)
        }
        let services = context.services, terminal = tab.kind == .pty
        // A terminal's session is its agent's report (a hook's `agent_session_id`); a chat's, the outside session it adopted.
        let adopted = terminal ? nil : services.agentTabs.adoption(of: tab.id)
        let facts = WindowRules.ToggleFacts(terminal: terminal, chat: !terminal && services.agentTabs.isAgentTab(tab.id),
                                            agent: terminal ? tab.agent?.agent : adopted?.harness,
                                            session: terminal ? tab.agent?.harnessSessionID : adopted?.agentSessionId)
        // The route is Rust's (cmux-window-rules `tabs::terminal_chat_toggle`).
        switch WindowRules().terminalChatToggle(facts) {
        case .notAgentTab?, nil: throw ActionFailure(message: MiscHandlerStrings.terminalChatNotAgentTab)
        case .noSession?: throw ActionFailure(message: terminal ? MiscHandlerStrings.terminalChatNoSession : MiscHandlerStrings.terminalChatNoTerminal)
        case .unsupportedHarness?: throw ActionFailure(message: MiscHandlerStrings.terminalChatHarness)
        case .toTerminal(let harness, let session)?:
            // The live terminals running the session, best first (as an `agent/` link picks them).
            let running = services.machines.daemons.flatMap(\.store.reachableAgentHarnessSessions).filter { $0.tab != tab.id }
            let terminals = DeepLink.agentTabs(harness: harness, session: session, adopted: nil, harnessSessions: running)
            guard !terminals.isEmpty else { throw ActionFailure(message: MiscHandlerStrings.terminalChatNoTerminal) }
            // Showing it is a view change; a headless run leaves the user's focus alone.
            guard !invocation.allowsViewChange || terminals.contains(where: { services.revealTab($0) }) else {
                throw ActionFailure(message: MiscHandlerStrings.terminalChatNoTerminal)
            }
            return .done
        case .toChat(let harness, let session)?:
            let adopt = AgentPaneAdopt(harness: harness, agentSessionId: session)
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
}
