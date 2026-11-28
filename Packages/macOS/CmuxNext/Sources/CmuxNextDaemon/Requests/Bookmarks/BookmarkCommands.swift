import Foundation

// `bookmarks-v1` reads and creation (plans/cmux-next/bookmarks.md 2.1).

/// `list-bookmarks`: one profile's nodes, ordered by parent then index.
public struct ListBookmarksRequest: DaemonRequest {
    public typealias Response = BookmarkList
    public static let command = "list-bookmarks"
    public static let requiredCapability: String? = DaemonCapabilities.shared.bookmarks
    public var browserProfileID: String
    public init(browserProfileID: String) { self.browserProfileID = browserProfileID }
    enum CodingKeys: String, CodingKey { case browserProfileID = "browser_profile_id" }
}

/// `create-bookmark`: an existing `bookmark` id returns the stored node.
public struct CreateBookmarkRequest: DaemonRequest {
    public typealias Response = BookmarkResult
    public static let command = "create-bookmark"
    public static let requiredCapability: String? = DaemonCapabilities.shared.bookmarks
    public var bookmark: String?
    public var browserProfileID: String
    public var parent: String
    public var index: Int?
    public var kind: String
    public var title: String
    public var url: String?
    public var faviconKey: String?
    public var sourceKey: String?
    public var createdMs: Int64?
    /// The exactly-once key; reuse it on every retry of this write.
    public var mutation: MutationIdentity?

    public init(bookmark: String?, browserProfileID: String, parent: String, index: Int?, kind: String, title: String,
                url: String?, faviconKey: String?, sourceKey: String?, createdMs: Int64?, mutation: MutationIdentity?) {
        self.mutation = mutation
        self.bookmark = bookmark
        self.browserProfileID = browserProfileID
        self.parent = parent
        self.index = index
        self.kind = kind
        self.title = title
        self.url = url
        self.faviconKey = faviconKey
        self.sourceKey = sourceKey
        self.createdMs = createdMs
    }

    enum CodingKeys: String, CodingKey {
        case bookmark, parent, index, kind, title, url
        case browserProfileID = "browser_profile_id"
        case faviconKey = "favicon_key"
        case sourceKey = "source_key"
        case createdMs = "created_ms"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(bookmark, forKey: .bookmark)
        try c.encode(browserProfileID, forKey: .browserProfileID)
        try c.encode(parent, forKey: .parent)
        try c.encodeIfPresent(index, forKey: .index)
        try c.encode(kind, forKey: .kind)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(faviconKey, forKey: .faviconKey)
        try c.encodeIfPresent(sourceKey, forKey: .sourceKey)
        try c.encodeIfPresent(createdMs, forKey: .createdMs)
        try MutationFields(identity: mutation).encode(to: encoder)
    }
}
