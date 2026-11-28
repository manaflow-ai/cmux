public import Foundation

/// History matches for the typed text.
public final class HistorySuggestionProvider: BrowserSuggestionProvider, BrowserSuggestionDeleting {
    private let store: any BrowserHistoryStore
    private let limit: Int
    private let now: () -> Date

    public init(store: any BrowserHistoryStore, limit: Int = 6, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.limit = limit
        self.now = now
    }

    public func deleteSuggestion(_ url: URL) {
        store.removeEntry(for: url)
    }

    public func suggestions(for text: String) async -> [BrowserSuggestion] {
        let date = now()
        return store.entries
            .compactMap { entry -> BrowserSuggestion? in
                guard let score = BrowserHistoryRanker.score(entry, for: text, now: date) else { return nil }
                let display = BrowserURLDisplay.displayText(for: entry.url)
                return BrowserSuggestion(
                    kind: .history,
                    title: entry.title ?? display,
                    detail: display,
                    url: entry.url,
                    score: min(score, 999)
                )
            }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }
}

// MARK: - Search
