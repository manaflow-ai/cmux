public import Foundation

/// The revision-only payload emitted on `notification.feed.changed`.
public struct MobileNotificationFeedChangedEvent: Decodable, Equatable, Sendable {
    /// The newest feed revision known by the Mac.
    public let revision: Int

    /// Decodes a notification-feed invalidation event.
    /// - Parameter data: The raw event payload.
    /// - Returns: The decoded event, or `nil` when the payload is malformed.
    public static func decode(_ data: Data) -> MobileNotificationFeedChangedEvent? {
        try? JSONDecoder().decode(Self.self, from: data)
    }
}
