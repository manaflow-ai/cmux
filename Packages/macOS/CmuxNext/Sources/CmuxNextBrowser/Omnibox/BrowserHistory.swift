public import Foundation

/// A visited page.
public nonisolated struct BrowserHistoryEntry: Hashable, Sendable, Codable {
    public var url: URL
    public var title: String?
    public var visitCount: Int
    public var lastVisit: Date

    public init(url: URL, title: String?, visitCount: Int, lastVisit: Date) {
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.lastVisit = lastVisit
    }
}

/// Per-profile browsing history. The App layer owns persistence and chooses
/// one store per `BrowserProfileID`.
public protocol BrowserHistoryStore: AnyObject {
    func recordVisit(url: URL, title: String?, at date: Date)
    func updateTitle(_ title: String, for url: URL)
    /// Forgets the page (Shift-Delete on its omnibar row).
    func removeEntry(for url: URL)
    var entries: [BrowserHistoryEntry] { get }
}

/// History kept in memory. Good for demos, tests, and ephemeral profiles.
/// With `persistence` set, every visit, title and removal is also handed
/// to it (the omnibar still reads memory only).
public final class InMemoryBrowserHistory: BrowserHistoryStore {
    private var byKey: [String: BrowserHistoryEntry] = [:]
    public weak var persistence: (any BrowserHistoryPersistence)?

    public init(entries: [BrowserHistoryEntry] = []) {
        for entry in entries {
            byKey[BrowserHistoryRanker.dedupeKey(for: entry.url)] = entry
        }
    }

    public var entries: [BrowserHistoryEntry] {
        byKey.values.sorted { $0.lastVisit > $1.lastVisit }
    }

    public func recordVisit(url: URL, title: String?, at date: Date) {
        guard Self.isRecordable(url) else { return }
        let key = BrowserHistoryRanker.dedupeKey(for: url)
        if var entry = byKey[key] {
            entry.visitCount += 1
            entry.lastVisit = date
            entry.url = url
            if let title { entry.title = title }
            byKey[key] = entry
        } else {
            byKey[key] = BrowserHistoryEntry(url: url, title: title, visitCount: 1, lastVisit: date)
        }
        persistence?.didRecordVisit(url: url, title: title, at: date)
    }

    /// Adds entries from elsewhere (a browser import) without counting new
    /// visits: an entry replaces the stored one only when it is newer, and
    /// keeps the larger visit count.
    public func merge(_ entries: [BrowserHistoryEntry]) {
        for entry in entries where Self.isRecordable(entry.url) {
            let key = BrowserHistoryRanker.dedupeKey(for: entry.url)
            guard var existing = byKey[key] else {
                byKey[key] = entry
                continue
            }
            existing.visitCount = max(existing.visitCount, entry.visitCount)
            if entry.lastVisit > existing.lastVisit {
                existing.lastVisit = entry.lastVisit
                existing.title = entry.title ?? existing.title
            }
            byKey[key] = existing
        }
    }

    public func updateTitle(_ title: String, for url: URL) {
        let key = BrowserHistoryRanker.dedupeKey(for: url)
        guard let existing = byKey[key], existing.title != title else { return }
        byKey[key]?.title = title
        persistence?.didUpdateTitle(title, for: url)
    }

    public func removeEntry(for url: URL) {
        byKey[BrowserHistoryRanker.dedupeKey(for: url)] = nil
        persistence?.didRemoveEntry(for: url)
    }

    /// Forgets entries visited at or after `since` (nil: all) without
    /// telling `persistence` (the caller clears the durable log itself).
    public func forget(since: Date?) {
        guard let since else {
            byKey.removeAll()
            return
        }
        byKey = byKey.filter { $0.value.lastVisit < since }
    }

    /// Only web pages and local files go into history.
    static func isRecordable(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https", "file": true
        default: false
        }
    }
}
