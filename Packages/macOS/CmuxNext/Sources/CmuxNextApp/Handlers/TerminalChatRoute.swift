import CmuxNextAgentPane
import CmuxNextDaemon

/// What Open Terminal as Chat does with the focused terminal's agent status. Pure, so the decision
/// is tested without windows or a daemon.
enum TerminalChatRoute: Equatable {
    /// A tab (`TabModel.id`) already resumes this session: it is shown instead of a duplicate.
    case reveal(tab: String)
    /// A new agent chat tab in the terminal's pane resumes `adopt` over ACP (acpmux adopt).
    case open(AgentPaneAdopt)
    /// The terminal reports no agent session.
    case noSession
    /// The terminal's agent is not one acpmux can resume (only Claude Code and Codex).
    case unsupportedHarness

    /// Routes `status` (the terminal's `TabModel.agent`). `openTab` names the tab that already
    /// resumes an outside chat (``AgentTabStore``'s `tab(resuming:)`).
    static func route(_ status: AgentStatus?, openTab: (AgentPaneAdopt) -> String?) -> TerminalChatRoute {
        // The harness's own id: a hook report's `agent_session_id` (its `session` is a label).
        guard let session = status?.harnessSessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !session.isEmpty else {
            return .noSession
        }
        guard let harness = harness(of: status?.agent) else { return .unsupportedHarness }
        let adopt = AgentPaneAdopt(harness: harness, agentSessionId: session)
        return openTab(adopt).map { .reveal(tab: $0) } ?? .open(adopt)
    }

    /// The acpmux harness of a terminal agent's name, nil for agents acpmux does not adopt.
    static func harness(of agent: String?) -> String? {
        switch agent?.lowercased() {
        case "claude", "claude-code", "claude_code": "claude"
        case "codex": "codex"
        default: nil
        }
    }
}
