/// The strength of an agent turn-ending boundary.
public nonisolated enum AgentTurnBoundary: String, Codable, Sendable {
    /// A low-level end signal that remains provisional while work is active.
    case turnEnd = "turn_end"
    /// The integration has confirmed its own idle or settled condition.
    case settled
}
