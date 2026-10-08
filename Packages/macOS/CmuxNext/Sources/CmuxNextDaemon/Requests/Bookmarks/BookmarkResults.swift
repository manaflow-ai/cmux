import Foundation

// Results of the `bookmarks-v1` commands.

public struct BookmarkList: Decodable, Sendable, Equatable {
    public var revision: UInt64
    public var bookmarks: [BookmarkRecord]
    enum CodingKeys: String, CodingKey {
        case bookmarks
        case revision = "bookmarks_revision"
    }
}

public struct BookmarkResult: Decodable, Sendable, Equatable {
    public var bookmark: BookmarkRecord
    public var changed: Bool?
    /// True when the daemon replayed an earlier write with the same mutation key.
    public var replayed: Bool?
}

public struct BookmarkDeletion: Decodable, Sendable, Equatable {
    public var deleted: [String]
}
