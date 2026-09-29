public import Foundation

/// One row in the address bar dropdown.
public nonisolated struct BrowserSuggestion: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        /// Load the typed URL.
        case navigate
        /// Search for the typed or suggested query.
        case search
        /// A page from history.
        case history
    }

    public var kind: Kind
    /// Main line: page title or query.
    public var title: String
    /// Second line: display URL, or empty.
    public var detail: String
    public var url: URL
    /// Higher ranks first. Providers use `0...1000`.
    public var score: Double

    public var id: String { "\(kind)|\(url.absoluteString)" }

    public init(kind: Kind, title: String, detail: String, url: URL, score: Double) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.url = url
        self.score = score
    }
}

/// Source of suggestion rows. Providers must be cheap for local data; remote
/// providers should honor task cancellation, because every keystroke cancels
/// the previous query.
public protocol BrowserSuggestionProvider: AnyObject {
    func suggestions(for text: String) async -> [BrowserSuggestion]
}

// MARK: - History

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
    var entries: [BrowserHistoryEntry] { get }
}

/// History kept in memory. Good for demos, tests, and ephemeral profiles.
public final class InMemoryBrowserHistory: BrowserHistoryStore {
    private var byKey: [String: BrowserHistoryEntry] = [:]

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
    }

    public func updateTitle(_ title: String, for url: URL) {
        let key = BrowserHistoryRanker.dedupeKey(for: url)
        byKey[key]?.title = title
    }

    /// Only web pages and local files go into history.
    static func isRecordable(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https", "file": true
        default: false
        }
    }
}

/// Scores history entries against typed text. Pure, so it is unit tested.
public nonisolated enum BrowserHistoryRanker {
    /// Score for `entry` given `text`, or nil when it does not match.
    ///
    /// Every whitespace-separated token must match the URL or the title.
    /// Host-prefix matches score highest (typing "git" should offer
    /// github.com first), then URL prefix, then word starts in the title,
    /// then any substring. Frequency and recency break ties.
    public static func score(_ entry: BrowserHistoryEntry, for text: String, now: Date) -> Double? {
        let tokens = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return nil }

        let host = strippedHost(entry.url)
        let urlText = BrowserURLDisplay.displayText(for: entry.url).lowercased()
        let title = entry.title?.lowercased() ?? ""

        var match: Double = 0
        for (index, token) in tokens.enumerated() {
            let tokenScore: Double
            if index == 0, host.hasPrefix(token) {
                tokenScore = 600
            } else if index == 0, urlText.hasPrefix(token) {
                tokenScore = 450
            } else if title.hasPrefix(token) || title.contains(" " + token) {
                tokenScore = 300
            } else if urlText.contains(token) || title.contains(token) {
                tokenScore = 150
            } else {
                return nil
            }
            match += tokenScore
        }
        match /= Double(tokens.count)

        let frequency = log2(Double(max(entry.visitCount, 1))) * 40
        let ageDays = max(now.timeIntervalSince(entry.lastVisit), 0) / 86_400
        let recency = 120 * exp(-ageDays / 14)
        // Shorter URLs win among equal matches: the site root beats deep pages.
        let brevity = max(0, 40 - Double(urlText.count) / 4)
        return match + frequency + recency + brevity
    }

    /// Key that treats `http`/`https`, `www.`, and a trailing slash as equal.
    public static func dedupeKey(for url: URL) -> String {
        var text = BrowserURLDisplay.displayText(for: url).lowercased()
        if text.hasPrefix("http://") { text.removeFirst(7) }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }

    private static func strippedHost(_ url: URL) -> String {
        let host = url.host()?.lowercased() ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// History matches for the typed text.
public final class HistorySuggestionProvider: BrowserSuggestionProvider {
    private let store: any BrowserHistoryStore
    private let limit: Int
    private let now: () -> Date

    public init(store: any BrowserHistoryStore, limit: Int = 6, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.limit = limit
        self.now = now
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

/// Remote query completions (for example a search engine's suggest API).
public protocol BrowserSearchCompletionSource: AnyObject {
    func completions(for query: String) async -> [String]
}

/// Search rows for remote completions of the typed query.
public final class SearchSuggestionProvider: BrowserSuggestionProvider {
    public var searchEngine: BrowserSearchEngine
    private let source: any BrowserSearchCompletionSource
    private let limit: Int

    public init(searchEngine: BrowserSearchEngine, source: any BrowserSearchCompletionSource, limit: Int = 4) {
        self.searchEngine = searchEngine
        self.source = source
        self.limit = limit
    }

    public func suggestions(for text: String) async -> [BrowserSuggestion] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let completions = await source.completions(for: query)
        return completions
            .filter { $0.caseInsensitiveCompare(query) != .orderedSame }
            .prefix(limit)
            .enumerated()
            .compactMap { index, completion in
                guard let url = searchEngine.searchURL(for: completion) else { return nil }
                return BrowserSuggestion(
                    kind: .search, title: completion, detail: "", url: url, score: 200 - Double(index)
                )
            }
    }
}

// MARK: - Engine

/// Builds the dropdown: the "what you typed" row first, then provider rows
/// ranked by score, without duplicate destinations.
public final class OmniboxSuggestionEngine {
    public var resolver: OmniboxResolver
    public var providers: [any BrowserSuggestionProvider]
    public var maxResults: Int

    public init(resolver: OmniboxResolver = OmniboxResolver(), providers: [any BrowserSuggestionProvider] = [], maxResults: Int = 8) {
        self.resolver = resolver
        self.providers = providers
        self.maxResults = maxResults
    }

    public func suggestions(for text: String) async -> [BrowserSuggestion] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var rows: [BrowserSuggestion] = []
        if let primary = primarySuggestion(for: trimmed) {
            rows.append(primary)
        }

        var candidates: [BrowserSuggestion] = []
        for provider in providers {
            if Task.isCancelled { return [] }
            candidates += await provider.suggestions(for: trimmed)
        }
        candidates.sort { $0.score > $1.score }

        var seen = Set(rows.map { BrowserHistoryRanker.dedupeKey(for: $0.url) })
        for candidate in candidates where rows.count < maxResults {
            if seen.insert(BrowserHistoryRanker.dedupeKey(for: candidate.url)).inserted {
                rows.append(candidate)
            }
        }
        return rows
    }

    /// The row Enter picks when nothing is selected.
    public func primarySuggestion(for text: String) -> BrowserSuggestion? {
        switch resolver.destination(for: text) {
        case .url(let url):
            let display = BrowserURLDisplay.displayText(for: url)
            return BrowserSuggestion(kind: .navigate, title: display, detail: "", url: url, score: 1000)
        case .search(let query, let url):
            return BrowserSuggestion(
                kind: .search,
                title: query,
                detail: Strings.searchWith(engine: resolver.searchEngine.name),
                url: url,
                score: 1000
            )
        case nil:
            return nil
        }
    }
}
