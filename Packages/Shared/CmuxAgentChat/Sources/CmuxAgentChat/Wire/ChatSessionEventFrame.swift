/// The wire payload of one `chat.message` push event: a session id plus the
/// session event, exactly as the host published it.
public struct ChatSessionEventFrame: Sendable, Equatable, Codable {
    /// The session the event belongs to.
    public let sessionID: String

    /// The event itself.
    public let event: ChatSessionEvent

    /// Monotonic session revision associated with state/descriptor pushes.
    /// Older hosts omitted this field; clients treat `nil` as an
    /// unversioned best-effort event for wire compatibility.
    public let version: Int?

    /// Creates a frame.
    ///
    /// - Parameters:
    ///   - sessionID: The session the event belongs to.
    ///   - event: The event itself.
    public init(sessionID: String, event: ChatSessionEvent, version: Int? = nil) {
        self.sessionID = sessionID
        self.event = event
        self.version = version
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case event
        case version
    }
}
