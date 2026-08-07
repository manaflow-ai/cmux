/// Whether a turn event belongs to the currently authoritative turn.
public nonisolated enum AgentTurnFreshness: String, Codable, Sendable {
    /// The event belongs to the current turn.
    case current
    /// A newer or already-terminal turn supersedes the event.
    case superseded
    /// Available identifiers cannot prove the event's ordering.
    case unknown
}
