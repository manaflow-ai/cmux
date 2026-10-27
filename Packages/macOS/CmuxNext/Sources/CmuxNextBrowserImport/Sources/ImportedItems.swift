public import Foundation

/// A bookmark with its folder path from the source's root ("Bookmarks Bar", "Work").
public struct ImportedBookmark: Sendable, Codable, Hashable {
    public var title: String
    public var url: URL
    public var folderPath: [String]
    public var dateAdded: Date?

    public init(title: String, url: URL, folderPath: [String] = [], dateAdded: Date? = nil) {
        self.title = title
        self.url = url
        self.folderPath = folderPath
        self.dateAdded = dateAdded
    }
}

/// One history page, already aggregated per URL by the source.
public struct ImportedHistoryEntry: Sendable, Codable, Hashable {
    public var url: URL
    public var title: String?
    public var visitCount: Int
    public var lastVisit: Date

    /// Chromium keeps a URL's visit count in an `int` (history::URLRow::visit_count_); a source's
    /// count is clamped to 0 through this, so adding the visits that follow never overflows.
    public static let maximumVisitCount = Int(Int32.max)

    public init(url: URL, title: String?, visitCount: Int, lastVisit: Date) {
        self.url = url
        self.title = title
        self.visitCount = Self.clampedVisits(visitCount)
        self.lastVisit = lastVisit
    }

    /// `visits` more, clamped as the initializer clamps.
    public mutating func addVisits(_ visits: Int) {
        visitCount = Self.clampedVisits(Self.clampedVisits(visitCount) + Self.clampedVisits(visits))
    }

    static func clampedVisits(_ count: Int) -> Int { min(max(count, 0), maximumVisitCount) }
}

/// An open tab from the source's last session, in window then tab order.
public struct ImportedTab: Sendable, Codable, Hashable {
    public var url: URL
    public var title: String?
    public var window: Int
    public var pinned: Bool

    public init(url: URL, title: String?, window: Int = 0, pinned: Bool = false) {
        self.url = url
        self.title = title
        self.window = window
        self.pinned = pinned
    }
}
