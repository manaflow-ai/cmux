import AppKit
import CmuxBrowser
import CmuxSettings
import Foundation

struct OmnibarInlineCompletion: Equatable {
    let typedText: String
    let displayText: String
    let acceptedText: String

    var suffixRange: NSRange {
        let typedCount = typedText.utf16.count
        let fullCount = displayText.utf16.count
        return NSRange(location: typedCount, length: max(0, fullCount - typedCount))
    }
}

enum OmnibarInputIntent: Equatable {
    case urlLike
    case queryLike
    case ambiguous
}

func omnibarInputIntent(for query: String) -> OmnibarInputIntent {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .ambiguous }

    if resolveBrowserNavigableURL(trimmed) != nil {
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

func omnibarSuggestionCompletion(for suggestion: OmnibarSuggestion) -> String? {
    switch suggestion.kind {
    case .navigate(let url):
        return url
    case .history(let url, _):
        return url
    case .switchToTab(_, _, let url, _):
        return url
    default:
        return nil
    }
}

func omnibarSuggestionTitle(for suggestion: OmnibarSuggestion) -> String? {
    switch suggestion.kind {
    case .history(_, let title):
        return title
    case .switchToTab(_, _, _, let title):
        return title
    default:
        return nil
    }
}

func omnibarSuggestionMatchesTypedPrefix(
    typedText: String,
    suggestionCompletion: String,
    suggestionTitle: String? = nil
) -> Bool {
    let trimmedQuery = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else { return false }

    let query = trimmedQuery.lowercased()
    let trimmedCompletion = suggestionCompletion.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedCompletion.isEmpty else { return false }
    let loweredCompletion = trimmedCompletion.lowercased()

    let schemeStripped = stripHTTPSchemePrefix(trimmedCompletion)
    let schemeAndWWWStripped = stripHTTPSchemeAndWWWPrefix(trimmedCompletion)
    let typedIncludesScheme = query.hasPrefix("https://") || query.hasPrefix("http://")
    let typedIncludesWWWPrefix = query.hasPrefix("www.")

    if typedIncludesScheme, loweredCompletion.hasPrefix(query) { return true }
    if schemeStripped.hasPrefix(query) { return true }
    if !typedIncludesWWWPrefix && schemeAndWWWStripped.hasPrefix(query) { return true }

    let normalizedTitle = suggestionTitle?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? ""
    if !normalizedTitle.isEmpty && normalizedTitle.hasPrefix(query) {
        return true
    }

    return false
}

func omnibarSuggestionSupportsAutocompletion(query: String, suggestion: OmnibarSuggestion) -> Bool {
    if case .search = suggestion.kind { return false }
    if case .remote = suggestion.kind { return false }
    guard let completion = omnibarSuggestionCompletion(for: suggestion) else { return false }
    // Reject URLs whose host lacks a TLD (e.g. "https://news." → host "news").
    if let components = URLComponents(string: completion),
       let host = components.host?.lowercased() {
        let trimmedHost = host.hasSuffix(".") ? String(host.dropLast()) : host
        if !trimmedHost.contains(".") { return false }
    }
    let title = omnibarSuggestionTitle(for: suggestion)
    return omnibarSuggestionMatchesTypedPrefix(
        typedText: query,
        suggestionCompletion: completion,
        suggestionTitle: title
    )
}

func omnibarSingleCharacterQuery(for query: String) -> String? {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard trimmed.utf16.count == 1 else { return nil }
    return trimmed
}

func omnibarStrippedURL(_ value: String) -> String {
    return stripHTTPSchemeAndWWWPrefix(value)
}

func omnibarScoringCandidate(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }

    if let components = URLComponents(string: trimmed), let host = components.host?.lowercased() {
        let hostWithoutWWW = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let normalizedScheme = components.scheme?.lowercased()
        let isDefaultPort = (normalizedScheme == "http" && components.port == 80)
            || (normalizedScheme == "https" && components.port == 443)
        let portSuffix = {
            guard let port = components.port, !isDefaultPort else { return "" }
            return ":\(port)"
        }()

        var normalized = "\(hostWithoutWWW)\(portSuffix)"
        let path = components.percentEncodedPath
        if !path.isEmpty && path != "/" {
            normalized += path
        } else if path == "/" {
            normalized += "/"
        }

        if let query = components.percentEncodedQuery, !query.isEmpty {
            normalized += "?\(query)"
        }
        if let fragment = components.percentEncodedFragment, !fragment.isEmpty {
            normalized += "#\(fragment)"
        }
        return normalized
    }

    return stripHTTPSchemeAndWWWPrefix(trimmed)
}

func omnibarHasSingleCharacterPrefixMatch(query: String, url: String, title: String?) -> Bool {
    guard let trimmedQuery = omnibarSingleCharacterQuery(for: query) else { return false }

    let normalizedURL = omnibarStrippedURL(url).lowercased()
    let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    return normalizedURL.hasPrefix(trimmedQuery) || normalizedTitle.hasPrefix(trimmedQuery)
}

func buildOmnibarSuggestions(
    query: String,
    engineName: String,
    historyEntries: [BrowserHistoryStore.Entry],
    openTabMatches: [OmnibarOpenTabMatch] = [],
    remoteQueries: [String],
    resolvedURL: URL?,
    limit: Int = 8,
    now: Date = Date()
) -> [OmnibarSuggestion] {
    guard limit > 0 else { return [] }

    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedQuery.isEmpty {
        return Array(historyEntries.prefix(limit).map { .history($0) })
    }
    let singleCharacterQuery = omnibarSingleCharacterQuery(for: trimmedQuery)
    let isSingleCharacterQuery = singleCharacterQuery != nil
    let shouldIncludeRemoteSuggestions = !isSingleCharacterQuery
    let filteredHistoryEntries: [BrowserHistoryStore.Entry]
    let filteredOpenTabMatches: [OmnibarOpenTabMatch]
    if let singleCharacterQuery {
        filteredHistoryEntries = historyEntries.filter {
            omnibarHasSingleCharacterPrefixMatch(query: singleCharacterQuery, url: $0.url, title: $0.title)
        }
        filteredOpenTabMatches = openTabMatches.filter {
            omnibarHasSingleCharacterPrefixMatch(query: singleCharacterQuery, url: $0.url, title: $0.title)
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
    let intent = omnibarInputIntent(for: trimmedQuery)
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

        let scoringCandidate = omnibarScoringCandidate(c)
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
        let isAutocompletableMatch = omnibarSuggestionSupportsAutocompletion(query: trimmedQuery, suggestion: suggestion)

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
        insert(.history(entry), score: total)
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
    guard let preferred = omnibarPreferredAutocompletionSuggestionIndex(
        suggestions: suggestions,
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

func omnibarPreferredAutocompletionSuggestionIndex(
    suggestions: [OmnibarSuggestion],
    query: String
) -> Int? {
    guard !query.isEmpty else { return nil }

    var candidates: [(idx: Int, suffixLength: Int)] = []
    for (idx, suggestion) in suggestions.enumerated() {
        guard omnibarSuggestionSupportsAutocompletion(query: query, suggestion: suggestion) else { continue }
        guard let completion = omnibarSuggestionCompletion(for: suggestion) else { continue }
        let displayCompletion = omnibarSuggestionMatchesTypedPrefix(
            typedText: query,
            suggestionCompletion: completion,
            suggestionTitle: omnibarSuggestionTitle(for: suggestion)
        ) ? completion : ""
        guard !displayCompletion.isEmpty else { continue }

        let suffixLength = max(
            0,
            omnibarSuggestionDisplayText(forPrefixing: displayCompletion, query: query).utf16.count - query.utf16.count
        )
        candidates.append((idx: idx, suffixLength: suffixLength))
    }

    guard let preferred = candidates.min(by: {
        if $0.suffixLength != $1.suffixLength {
            return $0.suffixLength < $1.suffixLength
        }
        return $0.idx < $1.idx
    })?.idx else {
        return nil
    }

    return preferred
}

func omnibarSuggestionDisplayText(forPrefixing completion: String, query: String) -> String {
    let typedIncludesScheme = query.hasPrefix("https://") || query.hasPrefix("http://")
    let typedIncludesWWWPrefix = query.hasPrefix("www.")
    if typedIncludesScheme {
        return completion
    }
    if typedIncludesWWWPrefix {
        return stripHTTPSchemePrefix(completion)
    }
    return stripHTTPSchemeAndWWWPrefix(completion)
}

func stripHTTPSchemePrefix(_ raw: String) -> String {
    var normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized.hasPrefix("https://") {
        normalized.removeFirst("https://".count)
    } else if normalized.hasPrefix("http://") {
        normalized.removeFirst("http://".count)
    }
    return normalized
}

func stripHTTPSchemeAndWWWPrefix(_ raw: String) -> String {
    var normalized = stripHTTPSchemePrefix(raw)
    if normalized.hasPrefix("www.") {
        normalized.removeFirst("www.".count)
    }
    return normalized
}
