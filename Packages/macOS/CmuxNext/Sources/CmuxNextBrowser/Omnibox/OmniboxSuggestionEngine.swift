public import Foundation

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

    /// Shift-Delete on a history row: every provider that can forget `url`
    /// does (Chromium `AutocompleteController::DeleteMatch`).
    public func deleteSuggestion(_ url: URL) {
        for case let provider as any BrowserSuggestionDeleting in providers {
            provider.deleteSuggestion(url)
        }
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
