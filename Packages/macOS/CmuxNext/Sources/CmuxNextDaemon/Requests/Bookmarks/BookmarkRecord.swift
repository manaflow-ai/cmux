import Foundation

// Bookmarks of the home session (`bookmarks-v1`; plans/cmux-next/bookmarks.md
// section 2.1). Every change emits `bookmarks-changed`.

/// One node as the daemon reports it.
public struct BookmarkRecord: Decodable, Sendable, Equatable {
    public var id: String
    public var browserProfileID: String
    public var parent: String
    public var kind: String
    public var index: Int
    public var title: String
    public var url: String?
    public var faviconKey: String?
    public var sourceKey: String?
    public var createdMs: Int64
    public var lastUsedMs: Int64?
    /// A folder's icon (`bookmark-icon-v1`): one emoji, an SF Symbol name or a
    /// stored `image:`/`svg:sha256-<hex>` asset. Nil for none, for a URL
    /// bookmark, and from a daemon without the capability.
    public var icon: String?

    enum CodingKeys: String, CodingKey {
        case id, parent, kind, index, title, url, icon
        case browserProfileID = "browser_profile_id"
        case faviconKey = "favicon_key"
        case sourceKey = "source_key"
        case createdMs = "created_ms"
        case lastUsedMs = "last_used_ms"
    }
}
