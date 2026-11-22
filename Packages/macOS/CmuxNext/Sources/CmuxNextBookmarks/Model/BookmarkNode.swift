public import Foundation

/// The two fixed roots of every browser profile's tree (the bookmarks bar
/// and "Other Bookmarks"). They are not rows: their raw values are the
/// reserved `parent` of top-level nodes.
public nonisolated enum BookmarkRoot: String, CaseIterable, Sendable, Codable {
    case bar
    case other

    public static func isRoot(_ id: String) -> Bool { BookmarkRoot(rawValue: id) != nil }
}

/// One bookmark or folder (plans/cmux-next/bookmarks.md section 1). Order is
/// not stored on the node: `BookmarkTree` keeps each parent's children in order.
public nonisolated struct BookmarkNode: Sendable, Hashable, Identifiable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case url
        case folder
    }

    public var id: String
    /// `bar`, `other`, or a folder id in the same profile.
    public var parent: String
    public var kind: Kind
    public var title: String
    /// Set for `url` nodes only.
    public var url: URL?
    /// Favicon cache key (the page's origin), or nil.
    public var faviconKey: String?
    /// Folders made by a browser import: the source, so a re-import replaces them.
    public var sourceKey: String?
    public var created: Date
    public var lastUsed: Date?

    public init(id: String = BookmarkID.make(), parent: String, kind: Kind, title: String, url: URL? = nil,
                faviconKey: String? = nil, sourceKey: String? = nil, created: Date = Date(), lastUsed: Date? = nil) {
        self.id = id
        self.parent = parent
        self.kind = kind
        self.title = title
        self.url = url
        self.faviconKey = faviconKey
        self.sourceKey = sourceKey
        self.created = created
        self.lastUsed = lastUsed
    }

    public static func folder(_ title: String, in parent: String, id: String = BookmarkID.make(), created: Date = Date()) -> BookmarkNode {
        BookmarkNode(id: id, parent: parent, kind: .folder, title: title, created: created)
    }

    public static func bookmark(_ title: String, url: URL, in parent: String, id: String = BookmarkID.make(),
                                created: Date = Date()) -> BookmarkNode {
        BookmarkNode(id: id, parent: parent, kind: .url, title: title, url: url, faviconKey: BookmarkURL.faviconKey(for: url),
                     created: created)
    }

    public var isFolder: Bool { kind == .folder }

    /// The title, else the URL as shown in the omnibar (a bookmark with an
    /// empty name shows its URL).
    public var displayTitle: String {
        if !title.isEmpty { return title }
        return url.map(BookmarkURL.displayText) ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case id, parent, kind, title, url
        case faviconKey = "favicon_key"
        case sourceKey = "source_key"
        case created = "created_ms"
        case lastUsed = "last_used_ms"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        parent = try c.decode(String.self, forKey: .parent)
        kind = try c.decode(Kind.self, forKey: .kind)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url).flatMap(URL.init(string:))
        faviconKey = try c.decodeIfPresent(String.self, forKey: .faviconKey)
        sourceKey = try c.decodeIfPresent(String.self, forKey: .sourceKey)
        created = BookmarkTime.date(ms: try c.decodeIfPresent(Int64.self, forKey: .created) ?? 0)
        lastUsed = try c.decodeIfPresent(Int64.self, forKey: .lastUsed).map(BookmarkTime.date(ms:))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(parent, forKey: .parent)
        try c.encode(kind, forKey: .kind)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(url?.absoluteString, forKey: .url)
        try c.encodeIfPresent(faviconKey, forKey: .faviconKey)
        try c.encodeIfPresent(sourceKey, forKey: .sourceKey)
        try c.encode(BookmarkTime.ms(created), forKey: .created)
        try c.encodeIfPresent(lastUsed.map(BookmarkTime.ms), forKey: .lastUsed)
    }
}
