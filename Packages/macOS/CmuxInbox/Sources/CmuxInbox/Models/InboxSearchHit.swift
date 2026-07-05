import Foundation

/// One full-text search hit from the local inbox database.
public struct InboxSearchHit: Codable, Equatable, Identifiable, Sendable {
    /// Matched inbox item.
    public let item: InboxItem
    /// Thread containing the matched item.
    public let thread: InboxThread
    /// FTS snippet with local highlighting markers.
    public let snippet: String
    /// SQLite FTS rank; lower values are better.
    public let rank: Double

    /// Stable identity used by SwiftUI lists.
    public var id: String { item.itemID }

    /// Creates a search hit.
    public init(item: InboxItem, thread: InboxThread, snippet: String, rank: Double) {
        self.item = item
        self.thread = thread
        self.snippet = snippet
        self.rank = rank
    }
}
