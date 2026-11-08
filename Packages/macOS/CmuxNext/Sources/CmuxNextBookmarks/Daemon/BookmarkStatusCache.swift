public import Foundation

/// What the omnibar stars and the bookmarks bars must know in the same frame, per profile: the
/// home daemon's `bookmarks.status` for the pages that profile's tabs show, nothing more. It is read
/// again on every `bookmarks-changed`, so it holds one entry per page on screen, never the tree.
public nonisolated struct BookmarkStatusCache: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        var revision = -1
        var barFilled = false
        /// The ids of the links to each page shown (by its URL's text); a missing page is unknown.
        var matches: [String: [String]] = [:]
    }

    private var profiles: [String: Entry] = [:]

    public init() {}

    /// Whether `profile` was read (or edited here) at least once.
    public func knows(_ profile: String) -> Bool { profiles[profile] != nil }

    /// The ids of the links to the page `url`, nil while its status is unknown.
    public func ids(for url: URL, profile: String) -> [String]? {
        profiles[profile]?.matches[url.absoluteString]
    }

    /// Whether `profile`'s bar has something to show (an item, or Other Bookmarks).
    public func barFilled(_ profile: String) -> Bool { profiles[profile]?.barFilled == true }

    /// A status the daemon answered, for the pages `shown` now: an older revision than the one
    /// held is dropped, and pages no tab shows any more leave. True when what shows changed.
    public mutating func apply(_ status: BookmarkRoutedClient.Status, profile: String, shown: Set<String>) -> Bool {
        let held = profiles[profile]
        var entry = held ?? Entry()
        guard status.revision >= entry.revision else { return false }
        entry.revision = status.revision
        entry.barFilled = status.barFilled
        entry.matches = entry.matches.filter { shown.contains($0.key) }.merging(status.matches) { $1 }
        guard entry != held else { return false }
        profiles[profile] = entry
        return true
    }

    /// The star's own edit, shown before the daemon answers; its change event then confirms it.
    public mutating func note(_ ids: [String], url: URL, profile: String, barFilled: Bool? = nil) {
        var entry = profiles[profile] ?? Entry()
        entry.matches[url.absoluteString] = ids
        if let barFilled { entry.barFilled = barFilled }
        profiles[profile] = entry
    }

    public mutating func drop(_ profile: String) {
        profiles[profile] = nil
    }
}
