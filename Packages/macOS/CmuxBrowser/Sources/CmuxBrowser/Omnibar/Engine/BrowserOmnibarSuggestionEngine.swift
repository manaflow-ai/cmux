public import Foundation

/// Ranks the omnibar suggestion list from the typed query plus the available
/// inputs (history, open tabs, remote predictions, and a resolved navigable URL).
///
/// This is the pure ranking core behind the address bar: given a query it
/// classifies the input intent, scores every candidate with the frecency/intent
/// weighting the omnibar shipped with, deduplicates by completion, and promotes
/// the best inline-autocompletion row to the front. It holds one
/// constructor-injected dependency, `resolveNavigableURL`, because URL resolution
/// (localhost/loopback handling, scheme inference) lives in the app and is read
/// only to decide whether a query "looks like" a URL.
public struct BrowserOmnibarSuggestionEngine: Sendable {
    /// Resolves a typed query to a navigable URL, or `nil` when it is not
    /// URL-like. Supplied by the app so the engine stays free of WebKit/app
    /// host-parsing details while reproducing the exact navigation heuristics.
    public typealias NavigableURLResolving = @Sendable (String) -> URL?

    private let resolveNavigableURL: NavigableURLResolving

    /// Creates the engine with the app's navigable-URL resolver.
    public init(resolveNavigableURL: @escaping NavigableURLResolving) {
        self.resolveNavigableURL = resolveNavigableURL
    }

    /// Classifies how the omnibar should interpret `query`: `urlLike` when it
    /// resolves to a navigable URL, `queryLike` for plain search text, and
    /// `ambiguous` for a bare dotted token (e.g. `news.`) that could be either.
    public func inputIntent(for query: String) -> OmnibarInputIntent {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ambiguous }

        if resolveNavigableURL(trimmed) != nil {
            return .urlLike
        }

        if trimmed.contains(" ") {
            return .queryLike
        }

        if trimmed.contains(".") {
            return .ambiguous
        }

        return .queryLike
    }

    /// Builds the ranked omnibar suggestion list for `query`.
    ///
    /// Combines a search row, an optional direct-navigation row for `resolvedURL`,
    /// history hits, open-tab matches, and stale/remote predictions, scores each
    /// by query-intent and frecency, deduplicates by completion (preferring
    /// navigation over switch-to-tab on ties), sorts, truncates to `limit`, and
    /// promotes the best inline-autocompletion row to the front.
    public func buildSuggestions(
        query: String,
        engineName: String,
        historyEntries: [BrowserHistoryEntry],
        openTabMatches: [OmnibarOpenTabMatch] = [],
        remoteQueries: [String],
        resolvedURL: URL?,
        limit: Int = 8,
        now: Date = Date()
    ) -> [OmnibarSuggestion] {
        guard limit > 0 else { return [] }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            return Array(historyEntries.prefix(limit).map { .history(url: $0.url, title: $0.title) })
        }
        let singleCharacterQuery = trimmedQuery.omnibarSingleCharacterQuery
        let isSingleCharacterQuery = singleCharacterQuery != nil
        let shouldIncludeRemoteSuggestions = !isSingleCharacterQuery
        let filteredHistoryEntries: [BrowserHistoryEntry]
        let filteredOpenTabMatches: [OmnibarOpenTabMatch]
        if let singleCharacterQuery {
            filteredHistoryEntries = historyEntries.filter {
                OmnibarSuggestion.hasSingleCharacterPrefixMatch(query: singleCharacterQuery, url: $0.url, title: $0.title)
            }
            filteredOpenTabMatches = openTabMatches.filter {
                OmnibarSuggestion.hasSingleCharacterPrefixMatch(query: singleCharacterQuery, url: $0.url, title: $0.title)
            }
        } else {
            filteredHistoryEntries = historyEntries
            filteredOpenTabMatches = openTabMatches
        }

        let shouldSuppressSingleCharacterSearchResult = isSingleCharacterQuery
            && (!filteredHistoryEntries.isEmpty || !filteredOpenTabMatches.isEmpty)

        struct RankedSuggestion {
            let suggestion: OmnibarSuggestion
            let score: Double
            let order: Int
            let isAutocompletableMatch: Bool
            let kindPriority: Int
        }

        var bestByCompletion: [String: RankedSuggestion] = [:]
        var order = 0
        let intent = inputIntent(for: trimmedQuery)
        let normalizedQuery = trimmedQuery.lowercased()

        func suggestionPriority(for kind: OmnibarSuggestion.Kind) -> Int {
            switch kind {
            case .search:
                return 300
            case .remote:
                return 350
            default:
                return 0
            }
        }

        func completionScore(for candidate: String) -> Double {
            let c = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let q = normalizedQuery
            guard !c.isEmpty, !q.isEmpty else { return 0 }

            let scoringCandidate = c.omnibarScoringCandidate
            if !scoringCandidate.isEmpty {
                if scoringCandidate == q { return 260 }
                if scoringCandidate.hasPrefix(q) { return 220 }
                if scoringCandidate.contains(q) { return 150 }
            }

            if c == q { return 240 }
            if c.hasPrefix(q) { return 170 }
            if c.contains(q) { return 95 }
            return 0
        }

        func insert(_ suggestion: OmnibarSuggestion, score: Double) {
            let key = suggestion.completion.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { return }
            let isAutocompletableMatch = suggestion.supportsAutocompletion(query: trimmedQuery)

            let ranked = RankedSuggestion(
                suggestion: suggestion,
                score: score,
                order: order,
                isAutocompletableMatch: isAutocompletableMatch,
                kindPriority: suggestionPriority(for: suggestion.kind)
            )
            order += 1
            if let existing = bestByCompletion[key] {
                let shouldReplaceExisting: Bool = {
                    // For identical completions, keep "go to URL" over "switch to tab" so
                    // pressing Enter performs navigation unless the user explicitly picks a tab row.
                    switch (existing.suggestion.kind, ranked.suggestion.kind) {
                    case (.navigate, .switchToTab):
                        return false
                    case (.switchToTab, .navigate):
                        return true
                    default:
                        return ranked.score > existing.score
                    }
                }()
                if shouldReplaceExisting {
                    bestByCompletion[key] = ranked
                }
            } else {
                bestByCompletion[key] = ranked
            }
        }

        if !(isSingleCharacterQuery && shouldSuppressSingleCharacterSearchResult) {
            let searchBaseScore: Double
            switch intent {
            case .queryLike: searchBaseScore = 820
            case .ambiguous: searchBaseScore = 540
            case .urlLike: searchBaseScore = 140
            }
            insert(.search(engineName: engineName, query: trimmedQuery), score: searchBaseScore + completionScore(for: trimmedQuery))
        }

        if let resolvedURL {
            let completion = resolvedURL.absoluteString
            let navigateBaseScore: Double
            switch intent {
            case .urlLike: navigateBaseScore = 1_020
            case .ambiguous: navigateBaseScore = 760
            case .queryLike: navigateBaseScore = 470
            }
            insert(.navigate(url: completion), score: navigateBaseScore + completionScore(for: completion))
        }

        for (index, entry) in filteredHistoryEntries.prefix(max(limit * 2, limit)).enumerated() {
            let intentBaseScore: Double
            switch intent {
            case .urlLike: intentBaseScore = 780
            case .ambiguous: intentBaseScore = 690
            case .queryLike: intentBaseScore = 600
            }
            let urlMatch = completionScore(for: entry.url)
            let titleMatch = completionScore(for: entry.title ?? "") * 0.6
            let ageHours = max(0, now.timeIntervalSince(entry.lastVisited) / 3600)
            let recencyScore = max(0, 75 - (ageHours / 5))
            let visitScore = min(95, log1p(Double(max(1, entry.visitCount))) * 32)
            let typedScore = min(230, log1p(Double(max(0, entry.typedCount))) * 100)
            let typedRecencyScore: Double
            if let lastTypedAt = entry.lastTypedAt {
                let typedAgeHours = max(0, now.timeIntervalSince(lastTypedAt) / 3600)
                typedRecencyScore = max(0, 80 - (typedAgeHours / 5))
            } else {
                typedRecencyScore = 0
            }
            let positionScore = Double(max(0, 16 - index))
            let total = intentBaseScore + urlMatch + titleMatch + recencyScore + visitScore + typedScore + typedRecencyScore + positionScore
            insert(.history(url: entry.url, title: entry.title), score: total)
        }

        for (index, match) in filteredOpenTabMatches.prefix(limit).enumerated() {
            let intentBaseScore: Double
            switch intent {
            case .urlLike: intentBaseScore = 1_180
            case .ambiguous: intentBaseScore = 980
            case .queryLike: intentBaseScore = 820
            }
            let urlMatch = completionScore(for: match.url)
            let titleMatch = completionScore(for: match.title ?? "") * 0.65
            let positionScore = Double(max(0, 14 - index)) * 0.9
            let resolvedURLBonus: Double
            if let resolvedURL,
               resolvedURL.absoluteString.caseInsensitiveCompare(match.url) == .orderedSame {
                resolvedURLBonus = 120
            } else {
                resolvedURLBonus = 0
            }
            let total = intentBaseScore + urlMatch + titleMatch + positionScore + resolvedURLBonus
            if match.isKnownOpenTab {
                insert(
                    .switchToTab(tabId: match.tabId, panelId: match.panelId, url: match.url, title: match.title),
                    score: total
                )
            } else {
                insert(
                    OmnibarSuggestion.history(url: match.url, title: match.title),
                    score: total
                )
            }
        }

        if shouldIncludeRemoteSuggestions {
            for (index, remoteQuery) in remoteQueries.prefix(limit).enumerated() {
                let trimmedRemote = remoteQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedRemote.isEmpty else { continue }

                let remoteBaseScore: Double
                switch intent {
                case .queryLike: remoteBaseScore = 690
                case .ambiguous: remoteBaseScore = 450
                case .urlLike: remoteBaseScore = 110
                }
                let positionScore = Double(max(0, 14 - index)) * 0.9
                let total = remoteBaseScore + completionScore(for: trimmedRemote) + positionScore
                insert(.remoteSearchSuggestion(trimmedRemote), score: total)
            }
        }

        let sorted = bestByCompletion.values.sorted { lhs, rhs in
            if lhs.isAutocompletableMatch != rhs.isAutocompletableMatch {
                return lhs.isAutocompletableMatch
            }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.kindPriority != rhs.kindPriority {
                return lhs.kindPriority < rhs.kindPriority
            }
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.suggestion.completion < rhs.suggestion.completion
        }
        let suggestions = Array(sorted.map(\.suggestion).prefix(limit))
        return prioritizedAutocompletionSuggestions(suggestions: Array(suggestions), for: trimmedQuery)
    }

    private func prioritizedAutocompletionSuggestions(suggestions: [OmnibarSuggestion], for query: String) -> [OmnibarSuggestion] {
        guard let preferred = OmnibarSuggestion.preferredAutocompletionIndex(
            in: suggestions,
            query: query
        ) else {
            return suggestions
        }

        guard preferred != 0 else { return suggestions }

        var reordered = suggestions
        let suggestion = reordered.remove(at: preferred)
        reordered.insert(suggestion, at: 0)
        return reordered
    }

    /// Returns the previously fetched remote suggestions to keep showing while a
    /// fresh prediction request is in flight, or `[]` when they are no longer
    /// relevant (remote disabled, empty/unrelated query, or no stored results).
    /// Reused when the current and previous queries are equal or one is a prefix
    /// of the other, so nearby edits do not flash an empty remote section.
    public func staleRemoteSuggestionsForDisplay(
        query: String,
        previousRemoteQuery: String,
        previousRemoteSuggestions: [String],
        allowsRemoteSuggestions: Bool = true,
        limit: Int = 8
    ) -> [String] {
        guard allowsRemoteSuggestions else { return [] }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPreviousQuery = previousRemoteQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let loweredQuery = trimmedQuery.lowercased()
        let loweredPreviousQuery = trimmedPreviousQuery.lowercased()
        guard !trimmedQuery.isEmpty, !trimmedPreviousQuery.isEmpty else { return [] }
        guard loweredQuery == loweredPreviousQuery || loweredQuery.hasPrefix(loweredPreviousQuery) || loweredPreviousQuery.hasPrefix(loweredQuery) else {
            return []
        }
        guard !previousRemoteSuggestions.isEmpty else { return [] }
        let sanitized = previousRemoteSuggestions.compactMap { raw -> String? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed
        }

        if sanitized.isEmpty {
            return []
        }
        return Array(sanitized.prefix(limit))
    }
}
