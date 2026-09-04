import Foundation

/// The managed coding-agent providers whose terminal output can report context pressure.
public enum AgentContextProvider: String, Codable, CaseIterable, Hashable, Sendable {
    /// Anthropic's Claude Code terminal client.
    case claudeCode
    /// OpenAI's Codex terminal client.
    case codex

    /// Resolves a persisted managed-agent kind to a detector provider.
    ///
    /// Unknown or non-managed agent kinds intentionally return `nil`; context
    /// automation must never guess which TUI owns a terminal.
    ///
    /// - Parameter rawKind: The managed-session kind stored by agent-hook lifecycle state.
    public init?(managedAgentKind rawKind: String?) {
        switch rawKind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "claude", "claude_code", "claude-code":
            self = .claudeCode
        case "codex":
            self = .codex
        default:
            return nil
        }
    }
}
