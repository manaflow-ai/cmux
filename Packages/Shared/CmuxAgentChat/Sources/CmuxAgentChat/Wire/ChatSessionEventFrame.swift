/// The wire payload of one `chat.message` push event: a session id plus the
/// session event, exactly as the host published it.
public struct ChatSessionEventFrame: Sendable, Equatable, Codable {
    /// The session the event belongs to.
    public let sessionID: String

    /// The event itself.
    public let event: ChatSessionEvent

    /// Creates a frame.
    ///
    /// - Parameters:
    ///   - sessionID: The session the event belongs to.
    ///   - event: The event itself.
    public init(sessionID: String, event: ChatSessionEvent) {
        self.sessionID = sessionID
        self.event = event
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case event
    }
}
