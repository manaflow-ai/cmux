/// One chat message in the share-session history.
public struct ShareChatMessage: Codable, Equatable, Identifiable, Sendable {
    /// Stable message identifier.
    public var id: String

    /// Relay user identifier for the sender.
    public var user: String

    /// Message text.
    public var text: String

    /// Optional pane-anchored cursor bubble.
    public var bubble: ShareCursorPos?

    /// Unix timestamp in milliseconds.
    public var ts: Double

    /// Creates a chat message snapshot.
    public init(id: String, user: String, text: String, bubble: ShareCursorPos?, ts: Double) {
        self.id = id
        self.user = user
        self.text = text
        self.bubble = bubble
        self.ts = ts
    }
}
