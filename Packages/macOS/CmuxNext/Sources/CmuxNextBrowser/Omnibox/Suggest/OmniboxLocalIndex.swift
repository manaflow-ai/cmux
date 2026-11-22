public import Foundation

/// The phase A actor of one browser profile: owns the quick indexes
/// (history, bookmarks, open tabs) and answers local queries on its own
/// executor, never the main thread. One suggestion engine owns one.
public actor OmniboxLocalIndex {
    private var history: OmniboxQuickIndex
    private var bookmarks = OmniboxQuickIndex(admission: .all)
    private var tabs: [OmniboxTabRow] = []
    private var tabIndex = OmniboxQuickIndex(admission: .all)
    /// Dedupe key of an open tab's URL to the tab (the first tab with it).
    private var tabKeys: [String: String] = [:]

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

    /// URLs in the history index (tests, diagnostics).
    public var historyCount: Int { history.count }

    public func historyContains(_ url: URL) -> Bool { history.contains(url) }

    /// The local rows of `query`, or nil when a newer query of the same
    /// omnibar started (its gate moved on): stale work never delivers.
    public func run(_ query: OmniboxLocalQuery) -> [BrowserSuggestion]? {
        guard query.gate.isCurrent(query.generation) else { return nil }
        if query.tabs != tabs { indexTabs(query.tabs, now: query.now) }
        let rows = OmniboxPhaseA.rows(for: query, history: history, bookmarks: bookmarks, tabs: tabIndex, tabKeys: tabKeys)
        return query.gate.isCurrent(query.generation) ? rows : nil
    }

    private func indexTabs(_ rows: [OmniboxTabRow], now: Date) {
        tabs = rows
        tabKeys = [:]
        for tab in rows where tabKeys[BrowserHistoryRanker.dedupeKey(for: tab.url)] == nil {
            tabKeys[BrowserHistoryRanker.dedupeKey(for: tab.url)] = tab.key
        }
        tabIndex.reset(rows.map { OmniboxHistoryRow(url: $0.url, title: $0.title, visitCount: 1, lastVisit: now) }, now: now)
    }
}
