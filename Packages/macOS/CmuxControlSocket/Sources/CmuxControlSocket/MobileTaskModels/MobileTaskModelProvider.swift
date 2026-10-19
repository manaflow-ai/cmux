/// Coding-agent providers supported by mobile task model discovery.
public enum MobileTaskModelProvider: String, CaseIterable, Sendable {
    /// Anthropic's Claude Code CLI.
    case claude
    /// OpenAI's Codex CLI.
    case codex
    /// The OpenCode CLI.
    case openCode = "opencode"
}
