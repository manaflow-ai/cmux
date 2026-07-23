public import Foundation

/// The authoritative response from `notification.feed.list`.
public struct MobileNotificationFeedListResponse: Decodable, Equatable, Sendable {
    /// The Mac's monotonically increasing notification-feed revision.
    public let revision: Int
    /// The Mac's retained notifications, newest first.
    public let notifications: [MobileNotificationFeedListItem]

    /// Decodes a notification-feed list response.
    /// - Parameter data: The raw RPC result payload.
    /// - Returns: The decoded response.
    /// - Throws: A decoding error when the payload violates the feed contract.
    public static func decode(_ data: Data) throws -> MobileNotificationFeedListResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
