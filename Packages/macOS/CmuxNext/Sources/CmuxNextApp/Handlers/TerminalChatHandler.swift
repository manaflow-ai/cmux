import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon

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
        switch TerminalChatRoute.route(tab.agent, openTab: { services.agentTabs.tab(resuming: $0) }) {
        case .noSession:
            throw ActionFailure(message: MiscHandlerStrings.terminalChatNoSession)
        case .unsupportedHarness:
            throw ActionFailure(message: MiscHandlerStrings.terminalChatHarness)
        case .reveal(let existing):
            // Showing it is a view change; a headless run leaves the user's focus alone.
            guard invocation.allowsViewChange else { return }
            _ = services.revealTab(existing)
        case .open(let adopt):
            let seed = AgentPaneSeedSource(AgentPaneSeed(cwd: tab.cwd, adopt: adopt))
            let pending: AgentTabPending
            do {
                pending = try services.agentTabs.open(in: pane.pane.handle, of: pane.daemon, seed: seed, adopt: adopt)
            } catch let refusal as AgentTabRefusal {
                throw ActionFailure(message: refusal.message)
            }
            pane.selectWhenReported(surface: pending.surface)
            let logger = pane.daemon.logger
            // The chat's creation is awaited off main; its failure is the run's, told in one task on main.
            context.registry.trackWork(owner: "TerminalChatHandler.open", on: services.mainWork) {
                _ = try await pending.value()
            } then: { result in
                // A cancellation: the person closed the tab first.
                guard case .failure(let error) = result, !(error is CancellationError) else { return nil }
                logger.error("open-terminal-as-chat failed: \(String(describing: error), privacy: .public)")
                return ActionWorkFailure("open terminal as chat", error)
            }
        }
    }
}
