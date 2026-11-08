public import Foundation

/// The authoritative response from `notification.feed.list`.
public struct MobileNotificationFeedListResponse: Decodable, Equatable, Sendable {
    /// The Mac's monotonically increasing notification-feed revision.
    public let revision: Int
    /// The Mac's retained notifications, newest first.
    public let notifications: [MobileNotificationFeedListItem]

    /// Creates a feed list response from a revision and retained notifications.
    public init(
        revision: Int,
        notifications: [MobileNotificationFeedListItem]
    ) {
        self.revision = revision
        self.notifications = notifications
    }

    /// Decodes a notification-feed list response.
    /// - Parameter data: The raw RPC result payload.
    /// - Returns: The decoded response.
    /// - Throws: A decoding error when the payload violates the feed contract.
    public static func decode(_ data: Data) throws -> MobileNotificationFeedListResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }

    /// Creates a response by decoding only the newest retained prefix and bounding
    /// text before building
    /// the public response DTO. This is used for defensive phone ingress from
    /// older Macs that can send more rows or larger fields than current clients
    /// retain.
    public init(
        decodingBounded data: Data,
        maxNotifications: Int,
        stringLimits: MobileNotificationFeedListStringLimits
    ) throws {
        try Task.checkCancellation()
        let decoder = JSONDecoder()
        decoder.userInfo[.mobileNotificationFeedListBoundedDecodeOptions] = MobileNotificationFeedListBoundedDecodeOptions(
            maxNotifications: max(0, maxNotifications),
            stringLimits: stringLimits
        )
        self = try decoder.decode(MobileNotificationFeedListBoundedResponse.self, from: data).response
    }
}

extension CodingUserInfoKey {
    static let mobileNotificationFeedListBoundedDecodeOptions = CodingUserInfoKey(
        rawValue: "dev.cmux.mobileNotificationFeedListBoundedDecodeOptions"
    )!
}
