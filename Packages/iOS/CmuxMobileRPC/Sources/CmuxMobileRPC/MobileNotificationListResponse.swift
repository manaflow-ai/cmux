public import Foundation

/// The authoritative notification list and unread total returned by the Mac.
public struct MobileNotificationListResponse: Equatable, Sendable {
    /// Valid notification items in the order supplied by the Mac.
    public let items: [MobileNotificationFeedItem]
    /// The Mac's authoritative unread-notification total.
    public let unreadCount: Int

    /// Creates a notification list response.
    public init(items: [MobileNotificationFeedItem], unreadCount: Int) {
        self.items = items
        self.unreadCount = max(0, unreadCount)
    }

    /// Decodes a `notification.list` RPC result, skipping malformed entries.
    /// - Parameter data: The raw JSON RPC result payload.
    /// - Returns: The decoded list response.
    /// - Throws: A JSON error when the result is not a JSON object.
    public static func decode(_ data: Data) throws -> Self {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let payload = json as? [String: Any] else {
            throw DecodingError.typeMismatch(
                [String: Any].self,
                DecodingError.Context(codingPath: [], debugDescription: "Expected notification list object")
            )
        }
        let rawItems = (payload["notifications"] as? [Any]) ?? []
        let unreadCount = (payload["unread_count"] as? NSNumber)?.intValue ?? 0
        return Self(
            items: rawItems.compactMap { value in
                guard let itemPayload = value as? [String: Any] else { return nil }
                return MobileNotificationFeedItem(payload: itemPayload)
            },
            unreadCount: unreadCount
        )
    }
}
