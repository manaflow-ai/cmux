public import Foundation

/// One phase A query: everything the local rows depend on, as a value, so
/// the phase A actor never reads main-actor state.
public nonisolated struct OmniboxLocalQuery: Sendable {
    public var generation: UInt64
    public var gate: OmniboxGenerationGate
    /// The typed text, trimmed.
    public var text: String
    public var resolver: OmniboxResolver
    public var maxRows: Int
    /// Enabled sources, in tie-break order.
    public var sources: [OmniboxSource]
    public var inlineAutocomplete: Bool
    /// Open tabs of the profile, without the tab that asks.
    public var tabs: [OmniboxTabRow]
    public var now: Date

    public init(generation: UInt64, gate: OmniboxGenerationGate, text: String, resolver: OmniboxResolver, maxRows: Int = 8,
                sources: [OmniboxSource] = OmniboxSource.defaultOrder, inlineAutocomplete: Bool = true, tabs: [OmniboxTabRow] = [],
                now: Date = Date()) {
        self.generation = generation
        self.gate = gate
        self.text = text
        self.resolver = resolver
        self.maxRows = maxRows
        self.sources = sources
        self.inlineAutocomplete = inlineAutocomplete
        self.tabs = tabs
        self.now = now
    }
}

/// Phase A of the suggestion pipeline (plans/cmux-next/omnibar-suggestions.md,
/// "Pipeline"): the what-you-typed row, then the quick history index, open
/// tabs and bookmarks, merged, pure and synchronous. Inline autocomplete
/// comes only from here: the top row after what-you-typed, when its match
/// allows it.
public nonisolated struct OmniboxPhaseA {
    public init() {}

    static let bookmarkLimit = 4
    static let tabLimit = 3

    /// The local rows for `query`. `tabKeys` maps a tab row's dedupe key to its tab.
    public static func rows(for query: OmniboxLocalQuery, history: OmniboxQuickIndex, bookmarks: OmniboxQuickIndex,
                            tabs: OmniboxQuickIndex, tabKeys: [String: String]) -> [BrowserSuggestion] {
        let text = query.text
        let typed = Self.primary(for: text, resolver: query.resolver)
        var result = typed.map { [$0] } ?? []
        guard !text.isEmpty, text.utf16.count <= OmniboxText.maxInputLength else { return result }
        var candidates: [(row: BrowserSuggestion, key: String, order: Int, inline: Bool)] = []
        for (order, source) in query.sources.enumerated() {
            switch source {
            case .history:
                for match in history.search(text, now: query.now, limit: query.maxRows) {
                    candidates.append((Self.row(match, kind: .history), match.key, order, match.allowsInlineCompletion))
                }
            case .bookmarks:
                for match in bookmarks.search(text, now: query.now, limit: bookmarkLimit) {
                    candidates.append((Self.row(match, kind: .bookmark), match.key, order, match.allowsInlineCompletion))
                }
            case .tabs:
                for match in tabs.search(text, now: query.now, limit: tabLimit) {
                    var tab = Self.row(match, kind: .switchToTab)
                    tab.detail = Strings.switchToTab
                    tab.tabKey = tabKeys[match.key]
                    if tab.tabKey != nil { candidates.append((tab, match.key, order, false)) }
                }
            case .calculator:
                if let answer = OmniboxCalculator.row(for: text) { candidates.append((answer, "answer:" + answer.title, order, false)) }
            case .search:
                break
            }
        }
        candidates.sort { lhs, rhs in
            if lhs.row.score != rhs.row.score { return lhs.row.score > rhs.row.score }
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.row.url.absoluteString < rhs.row.url.absoluteString
        }
        var seen = Set<String>()
        if let typed, typed.kind == .navigate { seen.insert(BrowserHistoryRanker.dedupeKey(for: typed.url)) }
        var seenTabs: Set<String> = []
        var topAllowsInline: Bool?
        for candidate in candidates where result.count < query.maxRows {
            let fresh = candidate.row.kind == .switchToTab ? seenTabs.insert(candidate.key).inserted : seen.insert(candidate.key).inserted
            guard fresh else { continue }
            var chosen = candidate.row
            chosen.inlineCompletable = false
            if topAllowsInline == nil { topAllowsInline = candidate.inline }
            result.append(chosen)
        }
        let top = typed == nil ? 0 : 1
        if query.inlineAutocomplete, topAllowsInline == true, result.indices.contains(top) {
            result[top].inlineCompletable = true
        }
        return result
    }

    /// The what-you-typed row: the URL the text resolves to, or a search
    /// for it. Enter picks it when nothing is selected.
    public static func primary(for text: String, resolver: OmniboxResolver) -> BrowserSuggestion? {
        var row: BrowserSuggestion
        switch resolver.destination(for: text) {
        case .url(let url):
            row = BrowserSuggestion(kind: .navigate, title: BrowserURLDisplay.displayText(for: url), detail: "", url: url, score: 1000)
        case .search(let query, let url):
            row = BrowserSuggestion(kind: .search, title: query, detail: Strings.searchWith(engine: resolver.searchEngine.name),
                                    url: url, score: 1000)
        case nil:
            return nil
        }
        row.inlineCompletable = false
        return row
    }

    /// `local` (phase A, what-you-typed first) with rows of the App's other
    /// local providers, one row per page (the higher score wins; local rows
    /// win ties), at most `maxRows`.
    public static func merging(_ local: [BrowserSuggestion], _ extra: [BrowserSuggestion], maxRows: Int) -> [BrowserSuggestion] {
        guard !extra.isEmpty else { return local }
        let hasPrimary = local.first.map { $0.kind == .navigate || $0.kind == .search } ?? false
        var result = hasPrimary ? [local[0]] : []
        let ranked = (Array(local.dropFirst(hasPrimary ? 1 : 0)) + extra).enumerated().sorted { lhs, rhs in
            lhs.element.score != rhs.element.score ? lhs.element.score > rhs.element.score : lhs.offset < rhs.offset
        }.map(\.element)
        var seen = Set<String>()
        if let first = result.first, first.kind == .navigate { seen.insert(BrowserHistoryRanker.dedupeKey(for: first.url)) }
        var seenTabs: Set<String> = []
        for row in ranked where result.count < maxRows {
            let key = BrowserHistoryRanker.dedupeKey(for: row.url)
            let fresh = row.kind == .switchToTab ? seenTabs.insert(key).inserted : seen.insert(key).inserted
            if fresh { result.append(row) }
        }
        return result
    }

    private static func row(_ match: OmniboxQuickMatch, kind: BrowserSuggestion.Kind) -> BrowserSuggestion {
        let title = match.row.title.flatMap { $0.isEmpty ? nil : $0 } ?? match.display
        return BrowserSuggestion(kind: kind, title: title, detail: match.display, url: match.row.url, score: match.score)
    }
}
