/// A durable session lifecycle transition; renders as a centered caption.
///
/// Only lifecycle changes worth a permanent transcript row use this kind.
/// Transient working/idle state travels as ``ChatAgentState`` on the session
/// instead (product rule: one in-place typing indicator, no bubble spam).
public struct ChatStatusTransition: Sendable, Equatable, Codable {
    /// The transition that occurred.
    public enum Event: String, Sendable, Equatable, Codable {
        /// The agent session started.
        case sessionStarted = "session_started"
        /// The agent session ended.
        case sessionEnded = "session_ended"
        /// The user interrupted the agent.
        case interrupted
        /// The agent compacted its context window.
        case contextCompacted = "context_compacted"
    }

    /// The transition that occurred.
    public let event: Event

    /// Optional human-readable detail (e.g. an exit reason).
    public let detail: String?

    /// Creates a status transition.
    ///
    /// - Parameters:
    ///   - event: The transition that occurred.
    ///   - detail: Optional human-readable detail.
    public init(event: Event, detail: String? = nil) {
        self.event = event
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey {
        case event
        case detail
    }
}
