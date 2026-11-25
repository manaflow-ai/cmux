public import Foundation

/// The phase A actor of one browser profile: owns the quick indexes
/// (history, bookmarks, open tabs) and answers local queries on its own
/// executor, never the main thread. One suggestion engine owns one.
public actor OmniboxLocalIndex {
    private var history: OmniboxQuickIndex
    private var bookmarks = OmniboxQuickIndex(admission: .all)
    /// The profile's open tabs by tab key, as the App last set them.
    private var openTabs: [String: OmniboxTabRow] = [:]
    /// One row per open URL (the first tab on it, by key), for Switch to Tab rows.
    private var tabIndex = OmniboxQuickIndex(admission: .all)
    /// Dedupe key of an open URL to the tabs on it, in key order.
    private var tabKeys: [String: [String]] = [:]

    public init(cap: Int = OmniboxQuickIndex.defaultCap) {
        history = OmniboxQuickIndex(cap: cap)
    }

    /// History changes, in the order the source made them.
    public func apply(_ changes: [OmniboxHistoryChange], now: Date) {
        for change in changes { history.apply(change, now: now) }
    }

    /// Every bookmark of the profile; replaces the previous set. A bookmark
    /// counts as typed once (the user chose to keep it), so its host-prefix
    /// matches may complete inline.
    public func setBookmarks(_ rows: [OmniboxHistoryRow], now: Date) {
        bookmarks.reset(rows.map { row in
            var row = row
            row.typedCount = max(row.typedCount, 1)
            return row
        }, now: now)
    }

    /// The local rows of `query`, or nil when a newer query of the same
    /// omnibar started (its gate moved on): stale work never delivers.
    public func run(_ query: OmniboxLocalQuery) -> [BrowserSuggestion]? {
        guard query.gate.isCurrent(query.generation) else { return nil }
        let rows = OmniboxPhaseA.rows(for: query, history: history, bookmarks: bookmarks, tabs: tabIndex, tabKeys: tabKeys)
        return query.gate.isCurrent(query.generation) ? rows : nil
    }

    /// Tab `row.key` is open on `row.url` with `row.title` (opened, navigated or retitled): O(1) index work,
    /// never a walk of the other tabs.
    public func setOpenTab(_ row: OmniboxTabRow, now: Date) { // perf-hot: 0.1ms omnibar-key (each open, close or navigate of a tab)
        if let old = openTabs.updateValue(row, forKey: row.key) { detach(old, now: now) }
        let dedupe = BrowserHistoryRanker.dedupeKey(for: row.url)
        var keys = tabKeys[dedupe] ?? []
        keys.insert(row.key, at: keys.firstIndex { $0 > row.key } ?? keys.endIndex)
        tabKeys[dedupe] = keys
        reindex(dedupe, url: row.url, now: now)
    }

    /// Tab `key` closed, or shows nothing a Switch to Tab row can name (a New Tab page).
    public func removeOpenTab(_ key: String, now: Date) {
        guard let old = openTabs.removeValue(forKey: key) else { return }
        detach(old, now: now)
    }

    private func detach(_ row: OmniboxTabRow, now: Date) {
        let dedupe = BrowserHistoryRanker.dedupeKey(for: row.url)
        var keys = tabKeys[dedupe] ?? []
        keys.removeAll { $0 == row.key }
        tabKeys[dedupe] = keys.isEmpty ? nil : keys
        reindex(dedupe, url: row.url, now: now)
    }

    /// The index row of URL `dedupe`: the first tab still on it, or none. An open tab is open now: its row takes the
    /// most recency (a `lastVisit` in the future clamps to an age of 0), the same for every tab, so tab rows rank by
    /// their match alone and never by when a tab last changed (the list rebuild gave them all one time, too).
    private func reindex(_ dedupe: String, url: URL, now: Date) {
        if let first = tabKeys[dedupe]?.first, let row = openTabs[first] {
            tabIndex.upsert(OmniboxHistoryRow(url: row.url, title: row.title, visitCount: 1, lastVisit: .distantFuture), now: now)
        } else {
            tabIndex.remove(url)
        }
    }
}
