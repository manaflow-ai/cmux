/// The canonical presentation status of the agent(s) attached to one surface or pane.
///
/// This is the single source of truth for agent status colors: the native pane border and
/// custom sidebars both resolve to `AgentStatus` and read its `tintHex`, so a pane and its
/// sidebar row always read as the same signal. Raw values are the stable wire/JSON/sidebar
/// vocabulary (`set_agent_lifecycle` accepts the same strings) — never rename a case.
public enum AgentStatus: String, Codable, Sendable, Equatable, CaseIterable {
    /// No agent is reporting (an empty or unknown-only lifecycle map): a plain terminal.
    case none
    /// The agent is actively working.
    case running
    /// The agent finished its turn ("ready" in older user sidebars).
    case idle
    /// The agent is blocked waiting on user input.
    case needsInput
    /// The agent errored or ran out of quota (quota exhaustion folds into this at parse).
    case error

    /// Attention precedence for reducing several agents to one status; lower wins.
    public var attentionRank: Int {
        switch self {
        case .error: 0
        case .needsInput: 1
        case .running: 2
        case .idle: 3
        case .none: 4
        }
    }

    /// The canonical tint for the status, or `nil` for `.none` — each renderer picks its
    /// own no-agent neutral (pane borders draw black; sidebars use their own muted color).
    public var tintHex: String? {
        switch self {
        case .error: "#FF453A"
        case .needsInput: "#FF9F0A"
        case .running: "#0A84FF"
        case .idle: "#30D158"
        case .none: nil
        }
    }
}
