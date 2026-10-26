/// The coding agent behind an agent hook, from its hook source token.
public enum AgentKind: String, Sendable, CaseIterable {
    case claudeCode = "claude_code"
    case codex
    case opencode
    case gemini
    case cursor
    case pi
    case other

    /// Maps a hook `source` token. Unknown tokens become ``other`` so a new
    /// integration can never leak an arbitrary string.
    public init(hookSource: String) {
        switch hookSource.lowercased() {
        case "claude", "claude-code", "claude_code", "claudecode": self = .claudeCode
        case "codex": self = .codex
        case "opencode", "open-code": self = .opencode
        case "gemini", "gemini-cli": self = .gemini
        case "cursor", "cursor-agent": self = .cursor
        case "pi", "cmux-pi-extension": self = .pi
        default: self = .other
        }
    }
}
