/// Identifies one conversation on one backend.
///
/// The value is opaque to everything above the backend adapter: acpmux uses
/// its session id, another backend may use a thread or chat id.
public struct ConversationID: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The backend's own identifier.
    public let rawValue: String

    /// Creates an identifier from the backend's own value.
    /// - Parameter rawValue: The backend's identifier for the conversation.
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// The raw identifier.
    public var description: String { rawValue }
}
