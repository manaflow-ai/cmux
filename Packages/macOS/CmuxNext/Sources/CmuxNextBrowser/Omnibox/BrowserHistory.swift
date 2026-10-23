public import Foundation

/// A visited page.
public nonisolated struct BrowserHistoryEntry: Hashable, Sendable, Codable {
    public var url: URL
    public var title: String?
    public var visitCount: Int
    /// Visits typed in the omnibar (in memory until the daemon owns visits, H3).
    public var typedCount: Int
    public var lastVisit: Date

    public init(url: URL, title: String?, visitCount: Int, typedCount: Int = 0, lastVisit: Date) {
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.typedCount = typedCount
        self.lastVisit = lastVisit
    }

    enum CodingKeys: String, CodingKey { case url, title, visitCount, typedCount, lastVisit }

    /// Entries written before `typedCount` existed decode with 0.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(URL.self, forKey: .url)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        visitCount = try container.decode(Int.self, forKey: .visitCount)
        typedCount = try container.decodeIfPresent(Int.self, forKey: .typedCount) ?? 0
        lastVisit = try container.decode(Date.self, forKey: .lastVisit)
    }

    /// The omnibar index's view of this entry.
    public var omniboxRow: OmniboxHistoryRow {
        OmniboxHistoryRow(url: url, title: title, visitCount: visitCount, typedCount: typedCount, lastVisit: lastVisit)
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
/// to it (the omnibar still reads memory only). It is the omnibar's history
/// source until the daemon owns visits (`BrowserHistory+Source`).
public final class InMemoryBrowserHistory: BrowserHistoryStore {
    private var byKey: [String: BrowserHistoryEntry] = [:]
    public weak var persistence: (any BrowserHistoryPersistence)?
    /// Omnibar indexes following this history, by token.
    var observers: [Int: @MainActor (OmniboxHistoryChange) -> Void] = [:]
    var nextObserver = 1
    /// URLs (dedupe keys) whose next visit was typed in the omnibar.
    var pendingTyped: Set<String> = []

    public init(entries: [BrowserHistoryEntry] = []) {
        for entry in entries {
            byKey[BrowserHistoryRanker.dedupeKey(for: entry.url)] = entry
        }
    }

    public var entries: [BrowserHistoryEntry] {
        byKey.values.sorted { $0.lastVisit > $1.lastVisit }
    }

    /// The `limit` most recently visited entries, newest first: the head of ``entries`` without
    /// sorting every entry. A New Tab page lists 40 pages of a history an import can make tens of
    /// thousands long, and it is built on the key's turn of Cmd-T and Cmd-N.
    ///
    /// - Parameter limit: How many entries at most; 0 or less gives none.
    /// - Returns: At most `limit` entries, newest first.
    public func recent(_ limit: Int) -> [BrowserHistoryEntry] {
        guard limit > 0 else { return [] }
        var newest: [BrowserHistoryEntry] = []
        newest.reserveCapacity(limit + 1)
        for entry in byKey.values {
            if newest.count == limit, let oldest = newest.last, entry.lastVisit <= oldest.lastVisit { continue }
            // Binary search for the first kept entry older than this one (newest first).
            var low = 0, high = newest.count
            while low < high {
                let mid = (low + high) / 2
                if newest[mid].lastVisit >= entry.lastVisit { low = mid + 1 } else { high = mid }
            }
            newest.insert(entry, at: low)
            if newest.count > limit { newest.removeLast() }
        }
        return newest
    }

    public func recordVisit(url: URL, title: String?, at date: Date) {
        guard Self.isRecordable(url) else { return }
        let key = BrowserHistoryRanker.dedupeKey(for: url)
        let typed = pendingTyped.remove(key) == nil ? 0 : 1
        var entry = byKey[key] ?? BrowserHistoryEntry(url: url, title: title, visitCount: 0, lastVisit: date)
        entry.visitCount += 1
        entry.typedCount += typed
        entry.lastVisit = date
        entry.url = url
        if let title { entry.title = title }
        byKey[key] = entry
        persistence?.didRecordVisit(url: url, title: title, at: date)
        notify(.upsert([entry.omniboxRow]))
    }

    /// Adds entries from elsewhere (a browser import) without counting new
    /// visits: an entry replaces the stored one only when it is newer, and
    /// keeps the larger visit count.
    public func merge(_ entries: [BrowserHistoryEntry]) {
        var changed: [OmniboxHistoryRow] = []
        for entry in entries where Self.isRecordable(entry.url) {
            let key = BrowserHistoryRanker.dedupeKey(for: entry.url)
            guard var existing = byKey[key] else {
                byKey[key] = entry
                changed.append(entry.omniboxRow)
                continue
            }
            existing.visitCount = max(existing.visitCount, entry.visitCount)
            existing.typedCount = max(existing.typedCount, entry.typedCount)
            if entry.lastVisit > existing.lastVisit {
                existing.lastVisit = entry.lastVisit
                existing.title = entry.title ?? existing.title
            }
            byKey[key] = existing
            changed.append(existing.omniboxRow)
        }
        if !changed.isEmpty { notify(.upsert(changed)) }
    }

    public func updateTitle(_ title: String, for url: URL) {
        let key = BrowserHistoryRanker.dedupeKey(for: url)
        guard var existing = byKey[key], existing.title != title else { return }
        existing.title = title
        byKey[key] = existing
        persistence?.didUpdateTitle(title, for: url)
        notify(.upsert([existing.omniboxRow]))
    }

    public func removeEntry(for url: URL) {
        byKey[BrowserHistoryRanker.dedupeKey(for: url)] = nil
        persistence?.didRemoveEntry(for: url)
        notify(.remove([url]))
    }

    /// Forgets the pages of `host` without telling `persistence` (the caller
    /// removes the site from the durable log itself, as one removal).
    public func forget(host: String) {
        let host = host.lowercased()
        let gone = byKey.filter { $0.value.url.host()?.lowercased() == host }
        guard !gone.isEmpty else { return }
        for key in gone.keys { byKey[key] = nil }
        notify(.remove(gone.values.map(\.url)))
    }

    /// An import's change: `entries` merge in, then the pages at `urls` go.
    public func apply(merging entries: [BrowserHistoryEntry], forgetting urls: [URL]) {
        if !entries.isEmpty { merge(entries) }
        if !urls.isEmpty { forget(urls: urls) }
    }

    /// Forgets the pages at `urls` without telling `persistence` (Remove
    /// Imported Data: the pages came from another browser, not the durable log).
    public func forget(urls: [URL]) {
        let keys = Set(urls.map(BrowserHistoryRanker.dedupeKey(for:)))
        let gone = byKey.filter { keys.contains($0.key) }
        guard !gone.isEmpty else { return }
        for key in gone.keys { byKey[key] = nil }
        notify(.remove(gone.values.map(\.url)))
    }

    /// Forgets entries visited at or after `since` (nil: all) without
    /// telling `persistence` (the caller clears the durable log itself).
    public func forget(since: Date?) {
        if let since {
            byKey = byKey.filter { $0.value.lastVisit < since }
        } else {
            byKey.removeAll()
        }
        notify(.reset(byKey.values.map(\.omniboxRow)))
    }

    /// Only web pages and local files go into history.
    static func isRecordable(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https", "file": true
        default: false
        }
    }
}
