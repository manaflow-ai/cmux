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
enum TerminalChatHandler {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("palette.openTerminalChatView", run: { try open($0, context: context) })
    }

    private static func open(_ invocation: ActionInvocation, context: AppActionContext) throws {
        guard let (pane, id) = context.scope(invocation).tab, let tab = pane.tab(id), tab.kind == .pty else {
            throw ActionFailure(message: MiscHandlerStrings.noTerminal)
        }
        let services = context.services
        // The route is Rust's (cmux-window-rules `tabs::terminal_chat`): the harness's own id is a hook
        // report's `agent_session_id` (its `session` is a label).
        switch WindowRules().terminalChat(agent: tab.agent?.agent, session: tab.agent?.harnessSessionID) {
        case .noSession?, nil:
            throw ActionFailure(message: MiscHandlerStrings.terminalChatNoSession)
        case .unsupportedHarness?:
            throw ActionFailure(message: MiscHandlerStrings.terminalChatHarness)
        case .adopt(let harness, let session)?:
            let adopt = AgentPaneAdopt(harness: harness, agentSessionId: session)
            // A tab that already resumes this session is shown instead of a duplicate.
            if let existing = services.agentTabs.tab(resuming: adopt) {
                // Showing it is a view change; a headless run leaves the user's focus alone.
                guard invocation.allowsViewChange else { return }
                _ = services.revealTab(existing)
                return
            }
            let seed = AgentPaneSeedSource(AgentPaneSeed(cwd: tab.cwd, adopt: adopt))
            let pending: AgentTabPending
            do {
                pending = try services.agentTabs.open(in: pane.pane.handle, of: pane.daemon, seed: seed, adopt: adopt)
            } catch let refusal as AgentTabRefusal {
                throw ActionFailure(message: refusal.message)
            }
            pane.selectWhenReported(surface: pending.surface)
            let logger = pane.daemon.logger
            context.registry.track(Task { @MainActor in
                do {
                    _ = try await pending.value()
                    return nil
                } catch is CancellationError {
                    return nil // the person closed the tab first
                } catch {
                    logger.error("open-terminal-as-chat failed: \(String(describing: error), privacy: .public)")
                    return ActionWorkFailure("open terminal as chat", error)
                }
            })
        }
    }
}
