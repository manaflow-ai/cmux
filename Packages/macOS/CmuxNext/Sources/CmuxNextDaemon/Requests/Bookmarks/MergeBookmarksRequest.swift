import Foundation

/// `merge-bookmarks` (`bookmarks-merge-v1`): the daemon merges a Chromium
/// bookmark store's own `Bookmarks` file into the profile's tree, once per
/// `mergeKey` (plans/cmux-next/bookmarks.md section 4). The daemon parses the
/// file, skips what cmux already has and records the key.
public struct MergeBookmarksRequest: DaemonRequest {
    public typealias Response = BookmarkMergeResult
    public static let command = "merge-bookmarks"
    public static let requiredCapability: String? = DaemonCapabilities.shared.bookmarksMerge
    public var browserProfileID: String
    public var mergeKey: String
    /// The text of a Chromium `Bookmarks` file.
    public var chromiumBookmarks: String
    public var mutation: MutationIdentity?

    public init(browserProfileID: String, mergeKey: String, chromiumBookmarks: String, mutation: MutationIdentity?) {
        self.browserProfileID = browserProfileID
        self.mergeKey = mergeKey
        self.chromiumBookmarks = chromiumBookmarks
        self.mutation = mutation
    }

    enum CodingKeys: String, CodingKey {
        case browserProfileID = "browser_profile_id"
        case mergeKey = "merge_key"
        case chromiumBookmarks = "chromium_bookmarks"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(browserProfileID, forKey: .browserProfileID)
        try c.encode(mergeKey, forKey: .mergeKey)
        try c.encode(chromiumBookmarks, forKey: .chromiumBookmarks)
        try MutationFields(identity: mutation).encode(to: encoder)
    }
}

public struct BookmarkMergeResult: Decodable, Sendable, Equatable {
    /// False when the key was merged before: nothing changed.
    public var merged: Bool
    public var created: Int
    public var skipped: Int
}
