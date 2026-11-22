public import Foundation

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
