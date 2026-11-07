/// A Claude Code reasoning effort level, as accepted by `CLAUDE_CODE_EFFORT_LEVEL`.
public enum ClaudeEffortLevel: String, CaseIterable, Codable, Sendable {
    case low, medium, high, xhigh, max

    /// The environment variable Claude Code reads its effort from.
    public static let environmentKey = "CLAUDE_CODE_EFFORT_LEVEL"
    /// Set by cmux's session priority resume next to ``environmentKey``, to the same level. A
    /// recorded launch whose ``environmentKey`` has no equal marker got its level from the user.
    public static let sessionPriorityMarkerKey = "CMUX_SESSION_PRIORITY_EFFORT"
}
