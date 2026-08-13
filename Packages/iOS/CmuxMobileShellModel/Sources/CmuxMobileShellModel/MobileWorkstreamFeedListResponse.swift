public import Foundation

/// Authoritative revisioned coding-agent feed snapshot from one Mac.
public struct MobileWorkstreamFeedListResponse: Decodable, Equatable, Sendable {
    /// Host revision represented by this page.
    public let revision: UInt64
    /// Feed items in reverse chronological order.
    public let items: [MobileWorkstreamFeedListItem]
    /// Opaque cursor for the next older page.
    public let nextCursor: String?
    /// Whether the host retains items before this page.
    public let hasMore: Bool

    /// Creates a decoded Feed page.
    public init(
        revision: UInt64,
        items: [MobileWorkstreamFeedListItem],
        nextCursor: String?,
        hasMore: Bool
    ) {
        self.revision = revision
        self.items = items
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }

    private enum CodingKeys: String, CodingKey {
        case revision, items
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
    }

    /// Decodes a Feed page, accepting legacy responses without paging fields.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decode(UInt64.self, forKey: .revision)
        items = try container.decode([MobileWorkstreamFeedListItem].self, forKey: .items)
        nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }

    /// Decodes an authenticated RPC result envelope.
    public static func decode(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }
}

/// Revision-only invalidation for `workstream.feed.changed`.
public struct MobileWorkstreamFeedChangedEvent: Decodable, Equatable, Sendable {
    public let revision: UInt64

    public static func decode(_ data: Data) -> Self? {
        try? JSONDecoder().decode(Self.self, from: data)
    }
}
