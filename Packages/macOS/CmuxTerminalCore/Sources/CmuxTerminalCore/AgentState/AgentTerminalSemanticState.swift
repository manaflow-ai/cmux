/// A coding agent's semantic state inferred from current terminal evidence.
public enum AgentTerminalSemanticState: String, Sendable, Codable, CaseIterable, Equatable {
    /// No supported foreground agent or no safe classification.
    case unknown
    /// A supported agent is ready for another turn.
    case idle
    /// A supported agent is executing a turn or tool.
    case working
    /// A supported agent requires a human decision or credential.
    case blocked
}
