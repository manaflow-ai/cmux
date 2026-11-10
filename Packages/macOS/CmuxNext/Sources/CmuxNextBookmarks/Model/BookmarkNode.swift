public import Foundation

/// The two fixed roots of every browser profile's tree (the bookmarks bar
/// and "Other Bookmarks"). They are not rows: their raw values are the
/// reserved `parent` of top-level nodes.
public nonisolated enum BookmarkRoot: String, CaseIterable, Sendable, Codable {
    case bar
    case other

    public static func isRoot(_ id: String) -> Bool { BookmarkRoot(rawValue: id) != nil }
}

/// One bookmark or folder (plans/cmux-next/bookmarks.md section 1), as the home daemon's routed
/// `bookmarks.*` reads answer it. The app keeps no tree: each read brings the rows it needs, and a
/// placed row (`places: true`) also says where it is.
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
    /// A folder's own icon (`bookmark-icon-v1`): one emoji, an SF Symbol name,
    /// or a stored `image:`/`svg:sha256-<hex>` asset of the home daemon. Nil
    /// draws the folder symbol; a URL bookmark never has one.
    public var icon: String?
    /// Its position among its parent's children, in the daemon's tree when it was read.
    public var index: Int
    /// A placed row's root id (`bar`, `other`), then its folders' titles; empty otherwise.
    public var path: [String]
    /// A placed link's URL as a list shows it (`github.com/foo`), from the daemon.
    public var displayURL: String?

    public init(id: String = BookmarkID.make(), parent: String, kind: Kind, title: String, url: URL? = nil,
                faviconKey: String? = nil, sourceKey: String? = nil, created: Date = Date(), lastUsed: Date? = nil,
                icon: String? = nil, index: Int = 0, path: [String] = [], displayURL: String? = nil) {
        self.id = id
        self.parent = parent
        self.kind = kind
        self.title = title
        self.url = url
        self.faviconKey = faviconKey
        self.sourceKey = sourceKey
        self.created = created
        self.lastUsed = lastUsed
        self.icon = icon
        self.index = index
        self.path = path
        self.displayURL = displayURL
    }

    public var isFolder: Bool { kind == .folder }

    /// The title, else the URL as a list shows it (a bookmark with an empty name shows its URL).
    public var displayTitle: String {
        if !title.isEmpty { return title }
        return displayURL ?? url?.absoluteString ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case id, parent, kind, title, url, icon, index, path
        case displayURL = "display_url"
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
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
        path = try c.decodeIfPresent([String].self, forKey: .path) ?? []
        displayURL = try c.decodeIfPresent(String.self, forKey: .displayURL)
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
        try c.encodeIfPresent(icon, forKey: .icon)
        try c.encode(index, forKey: .index)
    }
}
