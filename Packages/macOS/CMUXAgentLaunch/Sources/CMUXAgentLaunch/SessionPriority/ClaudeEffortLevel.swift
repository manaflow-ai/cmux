/// A Claude Code reasoning effort level, as accepted by `CLAUDE_CODE_EFFORT_LEVEL`.
public enum ClaudeEffortLevel: String, CaseIterable, Codable, Sendable {
    case low, medium, high, xhigh, max
}
