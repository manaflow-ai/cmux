import Foundation

// `bookmarks-v1` edits: update, move, delete.

/// `update-bookmark`: absent keeps; `.clear` sends null.
public struct UpdateBookmarkRequest: DaemonRequest {
    public typealias Response = BookmarkResult
    public static let command = "update-bookmark"
    public var bookmark: String
    public var title: String?
    public var url: String?
    public var faviconKey: FieldUpdate<String>
    public var lastUsedMs: FieldUpdate<Int64>

    public init(bookmark: String, title: String? = nil, url: String? = nil, faviconKey: FieldUpdate<String> = .unchanged,
                lastUsedMs: FieldUpdate<Int64> = .unchanged) {
        self.bookmark = bookmark
        self.title = title
        self.url = url
        self.faviconKey = faviconKey
        self.lastUsedMs = lastUsedMs
    }

    enum CodingKeys: String, CodingKey {
        case bookmark, title, url
        case faviconKey = "favicon_key"
        case lastUsedMs = "last_used_ms"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bookmark, forKey: .bookmark)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encode(faviconKey, forKey: .faviconKey)
        try c.encode(lastUsedMs, forKey: .lastUsedMs)
    }
}

/// `move-bookmark`: `index` is the final position among the new siblings.
public struct MoveBookmarkRequest: DaemonRequest {
    public typealias Response = BookmarkResult
    public static let command = "move-bookmark"
    public var bookmark: String
    public var parent: String
    public var index: Int
    public init(bookmark: String, parent: String, index: Int) {
        self.bookmark = bookmark
        self.parent = parent
        self.index = index
    }
}

/// `delete-bookmark`: removes the node and its subtree.
public struct DeleteBookmarkRequest: DaemonRequest {
    public typealias Response = BookmarkDeletion
    public static let command = "delete-bookmark"
    public var bookmark: String
    public init(bookmark: String) { self.bookmark = bookmark }
}
