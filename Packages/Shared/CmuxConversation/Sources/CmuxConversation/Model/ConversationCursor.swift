/// A position in one conversation's event history.
///
/// ``order`` increases with every event the backend records, so the reducer
/// can drop duplicates and fold pages that arrive out of order. ``token``
/// carries whatever the backend needs to resume from here (acpmux: the
/// sequence number; another backend: a timestamp or an ETag).
public struct ConversationCursor: Hashable, Sendable, Comparable, Codable {
    /// Monotonic position within the conversation.
    public let order: UInt64
    /// Backend-specific resume token for this position.
    public let token: String

    /// Creates a cursor.
    /// - Parameters:
    ///   - order: Monotonic position within the conversation.
    ///   - token: Backend-specific resume token; defaults to `order` as text.
    public init(order: UInt64, token: String? = nil) {
        self.order = order
        self.token = token ?? String(order)
    }

    /// Orders cursors by ``order``.
    public static func < (lhs: ConversationCursor, rhs: ConversationCursor) -> Bool {
        lhs.order < rhs.order
    }
}
