public import Foundation

/// The authoritative response from `notification.feed.list`.
public struct MobileNotificationFeedListResponse: Decodable, Equatable, Sendable {
    /// The Mac's monotonically increasing notification-feed revision.
    public let revision: Int
    /// The Mac's retained notifications, newest first.
    public let notifications: [MobileNotificationFeedListItem]

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

    /// Decodes only the newest retained prefix and bounds text before building
    /// the public response DTO. This is used for defensive phone ingress from
    /// older Macs that can send more rows or larger fields than current clients
    /// retain.
    public static func decodeBounded(
        _ data: Data,
        maxNotifications: Int,
        stringLimits: MobileNotificationFeedListStringLimits
    ) throws -> MobileNotificationFeedListResponse {
        let decoder = JSONDecoder()
        decoder.userInfo[.mobileNotificationFeedListBoundedDecodeOptions] = BoundedDecodeOptions(
            maxNotifications: max(0, maxNotifications),
            stringLimits: stringLimits
        )
        return try decoder.decode(BoundedResponse.self, from: data).response
    }
}

public struct MobileNotificationFeedListStringLimits: Sendable {
    public let identifierByteLimit: Int
    public let titleByteLimit: Int
    public let subtitleByteLimit: Int
    public let bodyByteLimit: Int
    public let metadataByteLimit: Int

    public init(
        identifierByteLimit: Int,
        titleByteLimit: Int,
        subtitleByteLimit: Int,
        bodyByteLimit: Int,
        metadataByteLimit: Int
    ) {
        self.identifierByteLimit = max(0, identifierByteLimit)
        self.titleByteLimit = max(0, titleByteLimit)
        self.subtitleByteLimit = max(0, subtitleByteLimit)
        self.bodyByteLimit = max(0, bodyByteLimit)
        self.metadataByteLimit = max(0, metadataByteLimit)
    }
}

private struct BoundedDecodeOptions: Sendable {
    let maxNotifications: Int
    let stringLimits: MobileNotificationFeedListStringLimits
}

private extension CodingUserInfoKey {
    static let mobileNotificationFeedListBoundedDecodeOptions = CodingUserInfoKey(
        rawValue: "dev.cmux.mobileNotificationFeedListBoundedDecodeOptions"
    )!
}

private struct BoundedResponse: Decodable {
    let response: MobileNotificationFeedListResponse

    private enum CodingKeys: String, CodingKey {
        case revision
        case notifications
    }

    init(from decoder: any Decoder) throws {
        let options = try Self.options(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let revision = try container.decode(Int.self, forKey: .revision)
        var notificationsContainer = try container.nestedUnkeyedContainer(forKey: .notifications)
        var notifications: [MobileNotificationFeedListItem] = []
        notifications.reserveCapacity(min(options.maxNotifications, notificationsContainer.count ?? options.maxNotifications))
        while !notificationsContainer.isAtEnd, notifications.count < options.maxNotifications {
            notifications.append(try notificationsContainer.decode(BoundedListItem.self).item)
        }
        response = MobileNotificationFeedListResponse(
            revision: revision,
            notifications: notifications
        )
    }

    private static func options(from decoder: any Decoder) throws -> BoundedDecodeOptions {
        if let options = decoder.userInfo[.mobileNotificationFeedListBoundedDecodeOptions] as? BoundedDecodeOptions {
            return options
        }
        let context = DecodingError.Context(
            codingPath: decoder.codingPath,
            debugDescription: "Missing bounded notification feed decode options"
        )
        throw DecodingError.dataCorrupted(context)
    }
}

private struct BoundedListItem: Decodable {
    let item: MobileNotificationFeedListItem

    private enum CodingKeys: String, CodingKey {
        case id
        case workspaceID = "workspace_id"
        case surfaceID = "surface_id"
        case title
        case subtitle
        case body
        case createdAt = "created_at"
        case isRead = "is_read"
        case retargetsToLiveSurfaceOwner = "retargets_to_live_surface_owner"
        case workspaceTitle = "workspace_title"
        case surfaceTitle = "surface_title"
    }

    init(from decoder: any Decoder) throws {
        let options = try Self.options(from: decoder)
        let limits = options.stringLimits
        let container = try decoder.container(keyedBy: CodingKeys.self)
        item = MobileNotificationFeedListItem(
            id: try Self.string(
                from: container,
                forKey: .id,
                limitedToUTF8Bytes: limits.identifierByteLimit
            ),
            workspaceID: try Self.string(
                from: container,
                forKey: .workspaceID,
                limitedToUTF8Bytes: limits.identifierByteLimit
            ),
            surfaceID: try Self.optionalString(
                from: container,
                forKey: .surfaceID,
                limitedToUTF8Bytes: limits.identifierByteLimit
            ),
            title: try Self.string(
                from: container,
                forKey: .title,
                limitedToUTF8Bytes: limits.titleByteLimit
            ),
            subtitle: try Self.optionalString(
                from: container,
                forKey: .subtitle,
                limitedToUTF8Bytes: limits.subtitleByteLimit
            ),
            body: try Self.string(
                from: container,
                forKey: .body,
                limitedToUTF8Bytes: limits.bodyByteLimit
            ),
            createdAt: Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .createdAt)),
            isRead: try container.decode(Bool.self, forKey: .isRead),
            retargetsToLiveSurfaceOwner: try container.decodeIfPresent(
                Bool.self,
                forKey: .retargetsToLiveSurfaceOwner
            ) ?? false,
            workspaceTitle: try Self.optionalString(
                from: container,
                forKey: .workspaceTitle,
                limitedToUTF8Bytes: limits.metadataByteLimit
            ),
            surfaceTitle: try Self.optionalString(
                from: container,
                forKey: .surfaceTitle,
                limitedToUTF8Bytes: limits.metadataByteLimit
            )
        )
    }

    private static func options(from decoder: any Decoder) throws -> BoundedDecodeOptions {
        if let options = decoder.userInfo[.mobileNotificationFeedListBoundedDecodeOptions] as? BoundedDecodeOptions {
            return options
        }
        let context = DecodingError.Context(
            codingPath: decoder.codingPath,
            debugDescription: "Missing bounded notification feed decode options"
        )
        throw DecodingError.dataCorrupted(context)
    }

    private static func string(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys,
        limitedToUTF8Bytes maxBytes: Int
    ) throws -> String {
        try string(
            container.decode(String.self, forKey: key),
            limitedToUTF8Bytes: maxBytes
        )
    }

    private static func optionalString(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys,
        limitedToUTF8Bytes maxBytes: Int
    ) throws -> String? {
        guard let value = try container.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        return string(value, limitedToUTF8Bytes: maxBytes)
    }

    private static func string(_ value: String, limitedToUTF8Bytes maxBytes: Int) -> String {
        guard maxBytes >= 0, value.utf8.count > maxBytes else { return value }
        var byteCount = 0
        var endIndex = value.startIndex
        while endIndex < value.endIndex {
            let nextIndex = value.index(after: endIndex)
            let characterByteCount = value[endIndex..<nextIndex].utf8.count
            guard byteCount + characterByteCount <= maxBytes else { break }
            byteCount += characterByteCount
            endIndex = nextIndex
        }
        return String(value[..<endIndex])
    }
}
