import Foundation

/// How Fork Conversation forks the agent a terminal runs. Pure, so every harness's route is
/// tested without windows, a terminal or a daemon. Beside ``AgentResume``, whose resume lines
/// open a fork made through ACP.
///
/// ```swift
/// switch TerminalAgentFork.route(agent: status.agent, session: status.harnessSessionID) {
/// case let .command(line): send(line)            // claude --resume <id> --fork-session
/// case let .acp(harness, session): forkThroughAcpmux(harness, session)  // Muse
/// case .noSession, .unsupported: refuse()
/// }
/// ```
public enum TerminalAgentFork: Equatable, Sendable {
    /// The agent's own CLI forks: this shell line, typed into the fork's new terminal.
    case command(String)
    /// The agent's CLI has no fork (Muse: `muse resume` only): acpmux forks `session` through the
    /// harness's ACP agent (`_acpmux/chat_fork`), then the new terminal resumes the fork
    /// (``resumeLine(harness:session:)``).
    case acp(harness: String, session: String)
    /// The terminal reports no harness session id that is one plain token.
    case noSession
    /// No way to fork this agent is known.
    case unsupported

    /// Routes the terminal's agent `agent` running harness session `session`.
    ///
    /// - Parameters:
    ///   - agent: The agent's name as the terminal reports it (`claude`, `codex`, `muse`).
    ///   - session: The harness's own session id: a hook report's `agent_session_id`, never its
    ///     `session` label. Nil when the terminal reports none.
    /// - Returns: How to fork it; `.noSession` for an id that is not one plain token.
    public static func route(agent: String?, session: String?) -> TerminalAgentFork {
        guard let session = session?.trimmingCharacters(in: .whitespacesAndNewlines),
              !session.isEmpty, !session.hasPrefix("cmux-hook-"),
              session.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return .noSession
        }
        switch agent?.lowercased() {
        case "claude", "claude-code", "claude_code": return .command("claude --resume \(session) --fork-session")
        case "codex": return .command("codex fork \(session)")
        case "grok": return .command("grok --resume \(session) --fork-session")
        case let agent? where resumeLine(harness: agent, session: session) != nil: return .acp(harness: agent, session: session)
        default: return .unsupported
        }
    }

    /// The shell line that opens forked session `session` of `harness` in a terminal, or nil when
    /// the harness has no resume command.
    ///
    /// - Parameters:
    ///   - harness: The terminal agent's name (`muse`).
    ///   - session: The fork's own session id.
    /// - Returns: The line, without a newline.
    public static func resumeLine(harness: String, session: String) -> String? {
        switch harness.lowercased() {
        // Agents whose CLI forks get `.command`; their resume never opens an ACP fork.
        case "claude", "claude-code", "claude_code", "codex", "grok": nil
        default: AgentResume.command(provider: harness, sessionID: session)
        }
    }
}
