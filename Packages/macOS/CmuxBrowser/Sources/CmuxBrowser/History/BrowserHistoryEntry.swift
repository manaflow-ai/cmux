public import Foundation

/// One persisted browser-history record: a visited URL with its display title
/// and the visit/typed statistics that feed omnibar frecency scoring.
///
/// The `Codable` shape is wire-compatible with the on-disk `browser_history.json`
/// produced by earlier cmux builds: `typedCount` and `lastTypedAt` decode as
/// `0`/`nil` when absent so histories written before typed-frecency landed keep
/// loading unchanged.
public struct BrowserHistoryEntry: Codable, Identifiable, Hashable, Sendable {
    /// Stable identity for SwiftUI list diffing; persisted so re-decoding a
    /// snapshot preserves row identity.
    public let id: UUID
    /// Absolute URL string exactly as recorded at visit time.
    public var url: String
    /// Page title, trimmed of surrounding whitespace, or `nil` when unknown.
    public var title: String?
    /// Timestamp of the most recent visit; histories are kept most-recent first.
    public var lastVisited: Date
    /// Total number of recorded visits to this URL.
    public var visitCount: Int
    /// Number of times the user typed (rather than followed a link to) this URL.
    public var typedCount: Int
    /// Timestamp of the most recent typed navigation, or `nil` if never typed.
    public var lastTypedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case url
        case title
        case lastVisited
        case visitCount
        case typedCount
        case lastTypedAt
    }

    /// Creates a history entry. `typedCount` and `lastTypedAt` default to the
    /// "never typed" state so link-followed visits omit them.
    public init(
        id: UUID,
        url: String,
        title: String?,
        lastVisited: Date,
        visitCount: Int,
        typedCount: Int = 0,
        lastTypedAt: Date? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.lastVisited = lastVisited
        self.visitCount = visitCount
        self.typedCount = typedCount
        self.lastTypedAt = lastTypedAt
    }

    /// Decodes an entry, defaulting `typedCount` to `0` and `lastTypedAt` to
    /// `nil` for snapshots written before those fields existed.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        url = try container.decode(String.self, forKey: .url)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        lastVisited = try container.decode(Date.self, forKey: .lastVisited)
        visitCount = try container.decode(Int.self, forKey: .visitCount)
        typedCount = try container.decodeIfPresent(Int.self, forKey: .typedCount) ?? 0
        lastTypedAt = try container.decodeIfPresent(Date.self, forKey: .lastTypedAt)
    }
}
