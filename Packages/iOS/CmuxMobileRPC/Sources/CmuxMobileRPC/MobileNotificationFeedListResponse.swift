public import Foundation

/// The authoritative response from `notification.feed.list`.
public struct MobileNotificationFeedListResponse: Decodable, Equatable, Sendable {
    /// The Mac's monotonically increasing notification-feed revision.
    public let revision: Int
    /// The Mac's retained notifications, newest first.
    public let notifications: [MobileNotificationFeedListItem]
    /// Pending agent decisions that can be completed inline.
    public let workstreams: [MobileNotificationFeedWorkstreamItem]

    private enum CodingKeys: String, CodingKey {
        case revision, notifications, workstreams
    }

    /// Creates a feed list response from a revision and retained notifications.
    public init(
        revision: Int,
        notifications: [MobileNotificationFeedListItem],
        workstreams: [MobileNotificationFeedWorkstreamItem] = []
    ) {
        self.revision = revision
        self.notifications = notifications
        self.workstreams = workstreams
    }

    /// Decodes older notification-only snapshots and current actionable snapshots.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decode(Int.self, forKey: .revision)
        notifications = try container.decode([MobileNotificationFeedListItem].self, forKey: .notifications)
        workstreams = try container.decodeIfPresent(
            [MobileNotificationFeedWorkstreamItem].self,
            forKey: .workstreams
        ) ?? []
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
