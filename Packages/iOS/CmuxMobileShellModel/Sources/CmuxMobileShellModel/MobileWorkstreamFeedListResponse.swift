public import Foundation

/// Authoritative revisioned coding-agent feed snapshot from one Mac.
public struct MobileWorkstreamFeedListResponse: Decodable, Equatable, Sendable {
    public let revision: UInt64
    public let items: [MobileWorkstreamFeedListItem]

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
