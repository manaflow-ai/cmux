import Bonsplit
import CmuxBrowser
import CmuxFoundation
import CmuxSettings
import CmuxSettingsUI
import WebKit
import AppKit

let browserOmnibarTextFieldIdentifier = NSUserInterfaceItemIdentifier("cmux.browserOmnibarTextField")

enum BrowserDevToolsIconOption: String, CaseIterable, Identifiable {
    case wrenchAndScrewdriver = "wrench.and.screwdriver"
    case wrenchAndScrewdriverFill = "wrench.and.screwdriver.fill"
    case curlyBracesSquare = "curlybraces.square"
    case curlyBraces = "curlybraces"
    case terminalFill = "terminal.fill"
    case terminal = "terminal"
    case hammer = "hammer"
    case hammerCircle = "hammer.circle"
    case ladybug = "ladybug"
    case ladybugFill = "ladybug.fill"
    case scope = "scope"
    case codeChevrons = "chevron.left.slash.chevron.right"
    case gearshape = "gearshape"
    case gearshapeFill = "gearshape.fill"
    case globe = "globe"
    case globeAmericas = "globe.americas.fill"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wrenchAndScrewdriver: return "Wrench + Screwdriver"
        case .wrenchAndScrewdriverFill: return "Wrench + Screwdriver (Fill)"
        case .curlyBracesSquare: return "Curly Braces"
        case .curlyBraces: return "Curly Braces (Plain)"
        case .terminalFill: return "Terminal (Fill)"
        case .terminal: return "Terminal"
        case .hammer: return "Hammer"
        case .hammerCircle: return "Hammer Circle"
        case .ladybug: return "Bug"
        case .ladybugFill: return "Bug (Fill)"
        case .scope: return "Scope"
        case .codeChevrons: return "Code Chevrons"
        case .gearshape: return "Gear"
        case .gearshapeFill: return "Gear (Fill)"
        case .globe: return "Globe"
        case .globeAmericas: return "Globe Americas (Fill)"
        }
    }
}

enum BrowserDevToolsIconColorOption: String, CaseIterable, Identifiable {
    case bonsplitInactive
    case bonsplitActive
    case accent
    case tertiary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bonsplitInactive: return "Bonsplit Inactive (Terminal/Globe)"
        case .bonsplitActive: return "Bonsplit Active (Terminal/Globe)"
        case .accent: return "Accent"
        case .tertiary: return "Tertiary"
        }
    }

    var nsColor: NSColor {
        switch self {
        case .bonsplitInactive:
            // Matches Bonsplit tab icon tint for inactive tabs.
            return .secondaryLabelColor
        case .bonsplitActive:
            // Matches Bonsplit tab icon tint for active tabs.
            return .labelColor
        case .accent:
            return cmuxAccentNSColor()
        case .tertiary:
            return .tertiaryLabelColor
        }
    }
}

enum BrowserDevToolsButtonDebugSettings {
    static let iconNameKey = "browserDevToolsIconName"
    static let iconColorKey = "browserDevToolsIconColor"
    static let defaultIcon = BrowserDevToolsIconOption.wrenchAndScrewdriver
    static let defaultColor = BrowserDevToolsIconColorOption.bonsplitInactive

    static func iconOption(defaults: UserDefaults = .standard) -> BrowserDevToolsIconOption {
        guard let raw = defaults.string(forKey: iconNameKey),
              let option = BrowserDevToolsIconOption(rawValue: raw) else {
            return defaultIcon
        }
        return option
    }

    static func colorOption(defaults: UserDefaults = .standard) -> BrowserDevToolsIconColorOption {
        guard let raw = defaults.string(forKey: iconColorKey),
              let option = BrowserDevToolsIconColorOption(rawValue: raw) else {
            return defaultColor
        }
        return option
    }

    static func copyPayload(defaults: UserDefaults = .standard) -> String {
        let icon = iconOption(defaults: defaults)
        let color = colorOption(defaults: defaults)
        return """
        browserDevToolsIconName=\(icon.rawValue)
        browserDevToolsIconColor=\(color.rawValue)
        """
    }
}

enum BrowserToolbarAccessorySpacingDebugSettings {
    static let key = "browserToolbarAccessorySpacing"
    static let defaultSpacing = 2
    static let supportedValues = [0, 2, 4, 6, 8]

    static func resolved(_ rawValue: Int) -> Int {
        supportedValues.contains(rawValue) ? rawValue : defaultSpacing
    }

    static func current(defaults: UserDefaults = .standard) -> Int {
        resolved(defaults.object(forKey: key) as? Int ?? defaultSpacing)
    }
}

enum BrowserProfilePopoverDebugSettings {
    static let horizontalPaddingKey = "browserProfilePopoverHorizontalPadding"
    static let verticalPaddingKey = "browserProfilePopoverVerticalPadding"
    static let defaultHorizontalPadding = 12.0
    static let defaultVerticalPadding = 10.0
    static let horizontalPaddingRange = 8.0...20.0
    static let verticalPaddingRange = 4.0...14.0

    static func resolvedHorizontalPadding(_ rawValue: Double) -> Double {
        horizontalPaddingRange.contains(rawValue) ? rawValue : defaultHorizontalPadding
    }

    static func resolvedVerticalPadding(_ rawValue: Double) -> Double {
        verticalPaddingRange.contains(rawValue) ? rawValue : defaultVerticalPadding
    }

    static func currentHorizontalPadding(defaults: UserDefaults = .standard) -> Double {
        resolvedHorizontalPadding((defaults.object(forKey: horizontalPaddingKey) as? NSNumber)?.doubleValue ?? defaultHorizontalPadding)
    }

    static func currentVerticalPadding(defaults: UserDefaults = .standard) -> Double {
        resolvedVerticalPadding((defaults.object(forKey: verticalPaddingKey) as? NSNumber)?.doubleValue ?? defaultVerticalPadding)
    }
}

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

private func omnibarPreferredAutocompletionSuggestionIndex(
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

private func omnibarSuggestionDisplayText(forPrefixing completion: String, query: String) -> String {
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

func staleOmnibarRemoteSuggestionsForDisplay(
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

func omnibarInlineCompletionForDisplay(
    typedText: String,
    suggestions: [OmnibarSuggestion],
    isFocused: Bool,
    selectionRange: NSRange,
    hasMarkedText: Bool
) -> OmnibarInlineCompletion? {
    guard isFocused else { return nil }
    guard !hasMarkedText else { return nil }

    let query = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return nil }
    let loweredQuery = query.lowercased()
    let typedIncludesScheme = loweredQuery.hasPrefix("https://") || loweredQuery.hasPrefix("http://")
    let typedIncludesWWWPrefix = loweredQuery.hasPrefix("www.")
    let queryCount = query.utf16.count

    let urlCandidate = suggestions.first { suggestion in
        guard let completion = omnibarSuggestionCompletion(for: suggestion) else { return false }
        return omnibarSuggestionMatchesTypedPrefix(
            typedText: query,
            suggestionCompletion: completion,
            suggestionTitle: omnibarSuggestionTitle(for: suggestion)
        )
    }
    guard let candidate = urlCandidate else {
        return nil
    }

    let acceptedText = candidate.completion
    let displayText: String
    if typedQueryHasExplicitPathOrQuery(query) {
        if typedIncludesScheme {
            displayText = acceptedText
        } else if typedIncludesWWWPrefix {
            displayText = stripHTTPSchemePrefix(acceptedText)
        } else {
            displayText = stripHTTPSchemeAndWWWPrefix(acceptedText)
        }
    } else if let hostOnlyDisplay = inlineCompletionHostDisplayText(
        for: acceptedText,
        typedIncludesScheme: typedIncludesScheme,
        typedIncludesWWWPrefix: typedIncludesWWWPrefix
    ) {
        displayText = hostOnlyDisplay
    } else {
        if typedIncludesScheme {
            displayText = acceptedText
        } else if typedIncludesWWWPrefix {
            displayText = stripHTTPSchemePrefix(acceptedText)
        } else {
            displayText = stripHTTPSchemeAndWWWPrefix(acceptedText)
        }
    }

    guard omnibarSuggestionSupportsAutocompletion(query: query, suggestion: candidate) else { return nil }
    // The display text must start with the typed query so the inline completion
    // visually extends what the user typed rather than replacing it (e.g. a
    // history entry matched via title "localhost:3000" whose URL is google.com
    // should not replace a typed "l" with "g").
    guard displayText.lowercased().hasPrefix(loweredQuery) else { return nil }
    guard displayText.utf16.count > queryCount else {
        return nil
    }

    let displayCount = displayText.utf16.count

    let resolvedSelectionRange: NSRange = {
        if selectionRange.location == NSNotFound {
            return NSRange(location: queryCount, length: 0)
        }
        let clampedLocation = min(selectionRange.location, displayCount)
        let remaining = max(0, displayCount - clampedLocation)
        let clampedLength = min(selectionRange.length, remaining)
        return NSRange(location: clampedLocation, length: clampedLength)
    }()

    let suffixRange = NSRange(location: queryCount, length: max(0, displayCount - queryCount))
    let isCaretAtTypedBoundary = (resolvedSelectionRange.length == 0 && resolvedSelectionRange.location == queryCount)
    let isSuffixSelection = NSEqualRanges(resolvedSelectionRange, suffixRange)
    let isSelectAllSelection = (resolvedSelectionRange.location == 0 && resolvedSelectionRange.length == displayCount)
    // Command+A can briefly report just the typed prefix selection before the full
    // select-all range lands. Keep inline completion alive through that transition.
    let typedPrefixSelection = NSRange(location: 0, length: queryCount)
    let isTypedPrefixSelection = NSEqualRanges(resolvedSelectionRange, typedPrefixSelection)
    guard isCaretAtTypedBoundary || isSuffixSelection || isSelectAllSelection || isTypedPrefixSelection else {
        return nil
    }

    return OmnibarInlineCompletion(typedText: query, displayText: displayText, acceptedText: acceptedText)
}

func omnibarDesiredSelectionRangeForInlineCompletion(
    currentSelection: NSRange,
    inlineCompletion: OmnibarInlineCompletion
) -> NSRange {
    let typedCount = inlineCompletion.typedText.utf16.count
    let typedPrefixSelection = NSRange(location: 0, length: typedCount)
    let displayCount = inlineCompletion.displayText.utf16.count
    let isSelectAll = currentSelection.location == 0 && currentSelection.length == displayCount
    if isSelectAll ||
        NSEqualRanges(currentSelection, inlineCompletion.suffixRange) ||
        NSEqualRanges(currentSelection, typedPrefixSelection) {
        return currentSelection
    }
    return inlineCompletion.suffixRange
}

func omnibarPublishedBufferTextForFieldChange(
    fieldValue: String,
    inlineCompletion: OmnibarInlineCompletion?,
    selectionRange: NSRange?,
    hasMarkedText: Bool
) -> String {
    guard !hasMarkedText else { return fieldValue }
    guard let inlineCompletion else { return fieldValue }
    guard fieldValue == inlineCompletion.displayText else { return fieldValue }
    guard let selectionRange else { return inlineCompletion.typedText }

    let typedCount = inlineCompletion.typedText.utf16.count
    let displayCount = inlineCompletion.displayText.utf16.count
    let typedPrefixSelection = NSRange(location: 0, length: typedCount)
    let isCaretAtTypedBoundary = selectionRange.location == typedCount && selectionRange.length == 0
    let isSuffixSelection = NSEqualRanges(selectionRange, inlineCompletion.suffixRange)
    let isSelectAllSelection = selectionRange.location == 0 && selectionRange.length == displayCount
    let isTypedPrefixSelection = NSEqualRanges(selectionRange, typedPrefixSelection)
    if isCaretAtTypedBoundary || isSuffixSelection || isSelectAllSelection || isTypedPrefixSelection {
        return inlineCompletion.typedText
    }

    return fieldValue
}

func omnibarInlineCompletionIfBufferMatchesTypedPrefix(
    bufferText: String,
    inlineCompletion: OmnibarInlineCompletion?
) -> OmnibarInlineCompletion? {
    guard let inlineCompletion else { return nil }
    guard bufferText == inlineCompletion.typedText else { return nil }
    return inlineCompletion
}

func omnibarPrefixAfterDeletingTrailingWord(from text: String) -> String {
    let nsText = text as NSString
    let fullRange = NSRange(location: 0, length: nsText.length)
    var deletionStart = nsText.length
    nsText.enumerateSubstrings(in: fullRange, options: [.byWords, .reverse]) { _, range, _, stop in
        deletionStart = range.location
        stop.pointee = true
    }
    return nsText.substring(to: deletionStart)
}

private func typedQueryHasExplicitPathOrQuery(_ typedQuery: String) -> Bool {
    var normalized = typedQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized.hasPrefix("https://") {
        normalized.removeFirst("https://".count)
    } else if normalized.hasPrefix("http://") {
        normalized.removeFirst("http://".count)
    }
    return normalized.contains("/") || normalized.contains("?") || normalized.contains("#")
}

private func inlineCompletionHostDisplayText(
    for acceptedText: String,
    typedIncludesScheme: Bool,
    typedIncludesWWWPrefix: Bool
) -> String? {
    guard let components = URLComponents(string: acceptedText),
          var host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          !host.isEmpty else {
        return nil
    }

    if !typedIncludesWWWPrefix, host.hasPrefix("www.") {
        host.removeFirst("www.".count)
    }

    let portSuffix: String
    if let port = components.port {
        let scheme = components.scheme?.lowercased()
        let isDefaultPort =
            (scheme == "https" && port == 443) ||
            (scheme == "http" && port == 80)
        portSuffix = isDefaultPort ? "" : ":\(port)"
    } else {
        portSuffix = ""
    }

    let hostWithPort = "\(host)\(portSuffix)"
    if typedIncludesScheme {
        let scheme = (components.scheme?.lowercased() == "http") ? "http" : "https"
        return "\(scheme)://\(hostWithPort)"
    }
    return hostWithPort
}

private func stripHTTPSchemePrefix(_ raw: String) -> String {
    var normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized.hasPrefix("https://") {
        normalized.removeFirst("https://".count)
    } else if normalized.hasPrefix("http://") {
        normalized.removeFirst("http://".count)
    }
    return normalized
}

private func stripHTTPSchemeAndWWWPrefix(_ raw: String) -> String {
    var normalized = stripHTTPSchemePrefix(raw)
    if normalized.hasPrefix("www.") {
        normalized.removeFirst("www.".count)
    }
    return normalized
}

// MARK: - Omnibar State Machine

struct OmnibarState: Equatable {
    var isFocused: Bool = false
    var currentURLString: String = ""
    var buffer: String = ""
    var suggestions: [OmnibarSuggestion] = []
    var selectedSuggestionIndex: Int = 0
    var selectedSuggestionID: String?
    /// True only while the current suggestion selection came from an explicit
    /// user action (arrow keys, Ctrl+N/P). Automatic highlighting (preferred
    /// autocompletion pick, popup reopen, pointer hover) leaves this false so
    /// a row auto-selected for an older query can never hijack Return.
    var selectionIsExplicit: Bool = false
    var isUserEditing: Bool = false
}

enum OmnibarEvent: Equatable {
    case focusGained(currentURLString: String, shouldSelectAll: Bool = false)
    case focusReasserted(shouldSelectAll: Bool = true)
    case focusLostRevertBuffer(currentURLString: String)
    case focusLostPreserveBuffer(currentURLString: String)
    case panelURLChanged(currentURLString: String)
    case bufferChanged(String)
    case suggestionsUpdated([OmnibarSuggestion])
    case moveSelection(delta: Int)
    case highlightIndex(Int)
    case escape
}

struct OmnibarEffects: Equatable {
    var shouldSelectAll: Bool = false
    var shouldBlurToWebView: Bool = false
    var shouldRefreshSuggestions: Bool = false
    var shouldClearInlineCompletion: Bool = false
    var shouldCancelPendingSuggestionRefresh: Bool = false
}

@discardableResult
func omnibarReduce(state: inout OmnibarState, event: OmnibarEvent) -> OmnibarEffects {
    var effects = OmnibarEffects()

    switch event {
    case .focusGained(let url, let shouldSelectAll):
        state.isFocused = true
        state.currentURLString = url
        state.buffer = url
        state.isUserEditing = false
        state.suggestions = []
        state.selectedSuggestionIndex = 0
        state.selectedSuggestionID = nil
        state.selectionIsExplicit = false
        effects.shouldSelectAll = shouldSelectAll
        effects.shouldCancelPendingSuggestionRefresh = true

    case .focusReasserted(let shouldSelectAll):
        state.isFocused = true
        effects.shouldSelectAll = shouldSelectAll
        if shouldSelectAll {
            // A Cmd+L style reassert restarts editing from the full selected
            // text; an earlier arrow selection no longer reflects Return
            // intent. Plain focus restoration (no select-all) keeps it.
            state.selectionIsExplicit = false
        }

    case .focusLostRevertBuffer(let url):
        state.isFocused = false
        state.currentURLString = url
        state.buffer = url
        state.isUserEditing = false
        state.suggestions = []
        state.selectedSuggestionIndex = 0
        state.selectedSuggestionID = nil
        state.selectionIsExplicit = false
        effects.shouldCancelPendingSuggestionRefresh = true

    case .focusLostPreserveBuffer(let url):
        state.isFocused = false
        state.currentURLString = url
        state.isUserEditing = false
        state.suggestions = []
        state.selectedSuggestionIndex = 0
        state.selectedSuggestionID = nil
        state.selectionIsExplicit = false
        effects.shouldCancelPendingSuggestionRefresh = true

    case .panelURLChanged(let url):
        state.currentURLString = url
        if !state.isUserEditing {
            state.buffer = url
            state.suggestions = []
            state.selectedSuggestionIndex = 0
            state.selectedSuggestionID = nil
            state.selectionIsExplicit = false
            effects.shouldCancelPendingSuggestionRefresh = true
        }

    case .bufferChanged(let newValue):
        let bufferChanged = state.buffer != newValue
        state.buffer = newValue
        if state.isFocused {
            state.isUserEditing = (newValue != state.currentURLString)
            state.selectedSuggestionIndex = 0
            state.selectedSuggestionID = nil
            state.selectionIsExplicit = false
            effects.shouldRefreshSuggestions = true
            effects.shouldClearInlineCompletion = bufferChanged
        }

    case .suggestionsUpdated(let items):
        let previousItems = state.suggestions
        let previousSelectedID = state.selectedSuggestionID
        state.suggestions = items
        if items.isEmpty {
            state.selectedSuggestionIndex = 0
            state.selectedSuggestionID = nil
            state.selectionIsExplicit = false
        } else if let previousSelectedID,
                  let existingIdx = items.firstIndex(where: { $0.id == previousSelectedID }) {
            // Same row carried across a refresh: an explicit selection stays explicit.
            state.selectedSuggestionIndex = existingIdx
            state.selectedSuggestionID = items[existingIdx].id
        } else if let preferredSuggestionIndex = omnibarPreferredAutocompletionSuggestionIndex(
            suggestions: items,
            query: state.buffer
        ) {
            state.selectedSuggestionIndex = preferredSuggestionIndex
            state.selectedSuggestionID = items[preferredSuggestionIndex].id
            state.selectionIsExplicit = false
        } else if previousItems.isEmpty {
            // Popup reopened: start keyboard focus from the first row.
            state.selectedSuggestionIndex = 0
            state.selectedSuggestionID = items[0].id
            state.selectionIsExplicit = false
        } else {
            state.selectedSuggestionIndex = min(max(0, state.selectedSuggestionIndex), items.count - 1)
            state.selectedSuggestionID = items[state.selectedSuggestionIndex].id
            state.selectionIsExplicit = false
        }

    case .moveSelection(let delta):
        guard !state.suggestions.isEmpty else { break }
        state.selectedSuggestionIndex = min(
            max(0, state.selectedSuggestionIndex + delta),
            state.suggestions.count - 1
        )
        state.selectedSuggestionID = state.suggestions[state.selectedSuggestionIndex].id
        state.selectionIsExplicit = true

    case .highlightIndex(let idx):
        guard !state.suggestions.isEmpty else { break }
        state.selectedSuggestionIndex = min(max(0, idx), state.suggestions.count - 1)
        state.selectedSuggestionID = state.suggestions[state.selectedSuggestionIndex].id
        // Pointer hover tracks the highlight but is not an explicit selection:
        // the popup can appear underneath a stationary cursor.
        state.selectionIsExplicit = false

    case .escape:
        guard state.isFocused else { break }
        // Chrome semantics:
        // - If user input is in progress OR the popup is open: revert to the page URL and select-all.
        // - Otherwise: exit omnibar focus.
        if state.isUserEditing || !state.suggestions.isEmpty {
            state.isUserEditing = false
            state.buffer = state.currentURLString
            state.suggestions = []
            state.selectedSuggestionIndex = 0
            state.selectedSuggestionID = nil
            state.selectionIsExplicit = false
            effects.shouldSelectAll = true
            effects.shouldCancelPendingSuggestionRefresh = true
        } else {
            effects.shouldBlurToWebView = true
        }
    }

    return effects
}

struct OmnibarSuggestion: Identifiable, Hashable {
    enum Kind: Hashable {
        case search(engineName: String, query: String)
        case navigate(url: String)
        case history(url: String, title: String?)
        case switchToTab(tabId: UUID, panelId: UUID, url: String, title: String?)
        case remote(query: String)
    }

    let kind: Kind

    // Stable identity prevents row teardown/rebuild flicker while typing.
    var id: String {
        switch kind {
        case .search(let engineName, let query):
            return "search|\(engineName.lowercased())|\(query.lowercased())"
        case .navigate(let url):
            return "navigate|\(url.lowercased())"
        case .history(let url, _):
            return "history|\(url.lowercased())"
        case .switchToTab(let tabId, let panelId, let url, _):
            return "switch-tab|\(tabId.uuidString.lowercased())|\(panelId.uuidString.lowercased())|\(url.lowercased())"
        case .remote(let query):
            return "remote|\(query.lowercased())"
        }
    }

    var completion: String {
        switch kind {
        case .search(_, let q): return q
        case .navigate(let url): return url
        case .history(let url, _): return url
        case .switchToTab(_, _, let url, _): return url
        case .remote(let q): return q
        }
    }

    var primaryText: String {
        switch kind {
        case .search(let engineName, let q):
            return "Search \(engineName) for \"\(q)\""
        case .navigate(let url):
            return Self.displayURLText(for: url)
        case .history(let url, let title):
            return (title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? Self.singleLineText(title) : Self.displayURLText(for: url)
        case .switchToTab(_, _, let url, let title):
            return (title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? Self.singleLineText(title) : Self.displayURLText(for: url)
        case .remote(let q):
            return q
        }
    }

    var listText: String {
        switch kind {
        case .history(let url, let title), .switchToTab(_, _, let url, let title):
            let titleOneline = Self.singleLineText(title)
            guard !titleOneline.isEmpty else { return Self.displayURLText(for: url) }
            return "\(titleOneline) — \(Self.displayURLText(for: url))"
        default:
            return primaryText
        }
    }

    var secondaryText: String? {
        switch kind {
        case .history(let url, let title):
            let titleOneline = Self.singleLineText(title)
            return titleOneline.isEmpty ? nil : Self.displayURLText(for: url)
        case .switchToTab(_, _, let url, let title):
            let titleOneline = Self.singleLineText(title)
            return titleOneline.isEmpty ? nil : Self.displayURLText(for: url)
        default:
            return nil
        }
    }

    var trailingBadgeText: String? {
        switch kind {
        case .switchToTab:
            return String(localized: "browser.switchToTab", defaultValue: "Switch to tab")
        default:
            return nil
        }
    }

    var isHistoryRemovable: Bool {
        if case .history = kind { return true }
        return false
    }

    static func history(_ entry: BrowserHistoryStore.Entry) -> OmnibarSuggestion {
        OmnibarSuggestion(kind: .history(url: entry.url, title: entry.title))
    }

    static func history(url: String, title: String?) -> OmnibarSuggestion {
        OmnibarSuggestion(kind: .history(url: url, title: title))
    }

    static func search(engineName: String, query: String) -> OmnibarSuggestion {
        OmnibarSuggestion(kind: .search(engineName: engineName, query: query))
    }

    static func navigate(url: String) -> OmnibarSuggestion {
        OmnibarSuggestion(kind: .navigate(url: url))
    }

    static func switchToTab(tabId: UUID, panelId: UUID, url: String, title: String?) -> OmnibarSuggestion {
        OmnibarSuggestion(kind: .switchToTab(tabId: tabId, panelId: panelId, url: url, title: title))
    }

    private static func singleLineText(_ value: String?) -> String {
        var normalized = (value ?? "").replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.contains("  ") {
            let collapsed = normalized.replacingOccurrences(of: "  ", with: " ")
            if collapsed == normalized { break }
            normalized = collapsed
        }
        return normalized
    }

    static func remoteSearchSuggestion(_ query: String) -> OmnibarSuggestion {
        OmnibarSuggestion(kind: .remote(query: query))
    }

    private static func displayURLText(for rawURL: String) -> String {
        guard let components = URLComponents(string: rawURL),
              var host = components.host else {
            return rawURL
        }

        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        host = host.lowercased()

        var result = host
        if let port = components.port {
            result += ":\(port)"
        }

        let path = components.percentEncodedPath
        if !path.isEmpty, path != "/" {
            result += path
        } else if path == "/" {
            result += "/"
        }

        if let query = components.percentEncodedQuery, !query.isEmpty {
            result += "?\(query)"
        }

        if result.isEmpty { return rawURL }
        return result
    }
}

func browserOmnibarShouldReacquireFocusAfterEndEditing(
    desiredOmnibarFocus: Bool,
    nextResponderIsOtherTextField: Bool
) -> Bool {
    desiredOmnibarFocus && !nextResponderIsOtherTextField
}

func browserOmnibarShouldSelectAllOnFocusReassertion(
    selectionIntent: BrowserAddressBarFocusSelectionIntent
) -> Bool {
    selectionIntent.shouldSelectAll
}

/// Whether a completed single click that just moved first responder into the
/// omnibar should select the field's entire contents (Chrome/Safari/Arc parity),
/// instead of leaving the caret the field editor placed at the click point.
///
/// The first click on an unfocused omnibar showing a URL selects everything so
/// the user can immediately type a replacement. A subsequent click (the field is
/// already first responder, so `gainedFocusOnThisClick` is `false`) keeps the
/// caret placement from https://github.com/manaflow-ai/cmux/issues/5268. A drag
/// or a Shift-click expresses an explicit range, so select-all defers to it; a
/// double-click never reaches this path (the field routes multi-clicks straight
/// to the field editor for word/line selection, and its second click lands after
/// this click's `mouseUp`, so word selection wins).
///
/// - Parameters:
///   - gainedFocusOnThisClick: `true` when the field had no field editor at
///     `mouseDown`, i.e. this click is the one that moved focus into the omnibar.
///   - isShiftClick: `true` when Shift was held, extending an explicit selection.
///   - didDrag: `true` when the pointer moved far enough to build a drag selection.
/// - Returns: `true` only for an undragged, unmodified focus-gaining click.
func browserOmnibarFocusGainingClickShouldSelectAll(
    gainedFocusOnThisClick: Bool,
    isShiftClick: Bool,
    didDrag: Bool
) -> Bool {
    gainedFocusOnThisClick && !isShiftClick && !didDrag
}

final class OmnibarNativeTextField: NSTextField {
    var panelId: UUID?
    var onPointerDown: (() -> Void)?
    var onHandleKeyEvent: ((NSEvent, NSTextView?) -> Bool)?
    var suppressNextFocusReacquireOnEndEditing = false
    /// Anchor index for Shift+click selection extension, reset on non-shift clicks.
    private var shiftClickAnchor: Int?
    private var mouseSelectionState: MouseSelectionState?
    private static let dragSelectionThreshold: CGFloat = 3

    private struct MouseSelectionState {
        let anchor: Int
        let initialWindowLocation: NSPoint
        var didDrag: Bool
        /// `true` when this click moved first responder into the omnibar, gating
        /// the Chrome-style select-all-on-focus behavior applied at `mouseUp`.
        let gainedFocus: Bool
        /// `true` when Shift was held, so an explicit selection extension overrides
        /// the focus-gaining select-all.
        let isShift: Bool
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = BrowserOmnibarPasteTextFieldCell(textCell: "")
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        lineBreakMode = .byTruncatingTail
        usesSingleLineMode = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func mouseDown(with event: NSEvent) {
        let hadEditor = currentEditor() != nil
        onPointerDown?()

        if !hadEditor {
            _ = window?.makeFirstResponder(self)
        }

        guard let editor = currentEditor() as? NSTextView else {
            super.mouseDown(with: event)
            return
        }

        let isShiftClick = event.modifierFlags.contains(.shift)

        // Keep multi-click word and line selection in the field editor, while avoiding
        // NSTextField's mouse tracking loop for ordinary clicks.
        if event.clickCount > 1 {
            mouseSelectionState = nil
            editor.mouseDown(with: event)
            shiftClickAnchor = nil
            return
        }

        let clickIndex = insertionIndex(for: event, in: editor)
        let anchor: Int
        if isShiftClick {
            let selected = editor.selectedRange()
            anchor = shiftClickAnchor ?? selected.location
            shiftClickAnchor = anchor
            setSelection(anchor: anchor, extent: clickIndex, in: editor)
        } else {
            anchor = clickIndex
            shiftClickAnchor = nil
            editor.setSelectedRange(NSRange(location: clickIndex, length: 0))
        }

        mouseSelectionState = MouseSelectionState(
            anchor: anchor,
            initialWindowLocation: event.locationInWindow,
            didDrag: false,
            gainedFocus: !hadEditor,
            isShift: isShiftClick
        )
    }

    override func mouseDragged(with event: NSEvent) {
        guard var state = mouseSelectionState,
              let editor = currentEditor() as? NSTextView else {
            super.mouseDragged(with: event)
            return
        }

        let dx = event.locationInWindow.x - state.initialWindowLocation.x
        let dy = event.locationInWindow.y - state.initialWindowLocation.y
        let distance = (dx * dx + dy * dy).squareRoot()
        if state.didDrag || distance >= Self.dragSelectionThreshold {
            state.didDrag = true
            setSelection(anchor: state.anchor, extent: insertionIndex(for: event, in: editor), in: editor)
            mouseSelectionState = state
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let state = mouseSelectionState else {
            super.mouseUp(with: event)
            return
        }
        mouseSelectionState = nil

        // Chrome/Safari/Arc parity: the click that moves first responder into the
        // omnibar selects the whole URL so the next keystroke replaces it. A click
        // while already focused keeps the caret placed in `mouseDown` (issue #5268),
        // and a drag or Shift-click keeps the explicit range built up during the
        // gesture. Double-clicks never reach here — `mouseDown` routes multi-clicks
        // to the field editor for word/line selection and leaves `mouseSelectionState`
        // nil, and the second click lands after this `mouseUp`, so word selection wins.
        // The keyboard path (Cmd+L) still selects all via the `selectAllRequestId` flow.
        guard browserOmnibarFocusGainingClickShouldSelectAll(
            gainedFocusOnThisClick: state.gainedFocus,
            isShiftClick: state.isShift,
            didDrag: state.didDrag
        ), let editor = currentEditor() as? NSTextView else {
            return
        }
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
    }

    private func insertionIndex(for event: NSEvent, in editor: NSTextView) -> Int {
        let localPoint = editor.convert(event.locationInWindow, from: nil)
        let index = editor.characterIndexForInsertion(at: localPoint)
        let textLength = (editor.string as NSString).length
        guard index != NSNotFound else { return textLength }
        return min(max(index, 0), textLength)
    }

    private func setSelection(anchor: Int, extent: Int, in editor: NSTextView) {
        if extent >= anchor {
            editor.setSelectedRange(NSRange(location: anchor, length: extent - anchor))
        } else {
            editor.setSelectedRange(NSRange(location: extent, length: anchor - extent))
        }
    }

    override func keyDown(with event: NSEvent) {
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        var route = "super"
        defer {
            CmuxTypingTiming.logDuration(
                path: "browser.omnibar.keyDown",
                startedAt: typingTimingStart,
                event: event,
                extra: "route=\(route)"
            )
        }
#endif
        // Reset shift-click anchor on any keyboard input so that a subsequent
        // Shift+click uses the post-keyboard selection as its anchor, not a
        // stale value from a prior mouse interaction.
        shiftClickAnchor = nil
        mouseSelectionState = nil
        if (currentEditor() as? NSTextView)?.hasMarkedText() == true {
            super.keyDown(with: event)
            return
        }
        if onHandleKeyEvent?(event, currentEditor() as? NSTextView) == true {
#if DEBUG
            route = "custom"
#endif
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        var handled = false
        defer {
            CmuxTypingTiming.logDuration(
                path: "browser.omnibar.performKeyEquivalent",
                startedAt: typingTimingStart,
                event: event,
                extra: "handled=\(handled ? 1 : 0)"
            )
        }
#endif
        shiftClickAnchor = nil
        mouseSelectionState = nil
        if (currentEditor() as? NSTextView)?.hasMarkedText() == true {
            let result = super.performKeyEquivalent(with: event)
#if DEBUG
            handled = result
#endif
            return result
        }
        if onHandleKeyEvent?(event, currentEditor() as? NSTextView) == true {
#if DEBUG
            handled = true
#endif
            return true
        }
        let result = super.performKeyEquivalent(with: event)
#if DEBUG
        handled = result
#endif
        return result
    }
}

@MainActor
struct OmnibarTextFieldNativeConfiguration {
    let panelId: UUID
    let fontSize: CGFloat
    let text: String
    let isFocused: Bool
    let selectAllRequestId: UInt64
    let inlineCompletion: OmnibarInlineCompletion?
    let placeholder: String
    let onTextChange: (String) -> Void
    let onFocusChange: (Bool) -> Void
    let onTap: () -> Void
    let onSubmit: (OmnibarLiveFieldSnapshot?) -> Void
    let onEscape: () -> Void
    let onFieldLostFocus: () -> Void
    let onMoveSelection: (Int) -> Void
    let onDeleteSelectedSuggestion: () -> Void
    let onAcceptInlineCompletion: () -> Void
    let onDeleteBackwardWithInlineSelection: () -> Void
    let onClearTypedPrefixWithInlineSelection: () -> Void
    let onDeleteWordBackwardWithInlineSelection: () -> Void
    let onSelectionChanged: (NSRange, Bool) -> Void
    let shouldSuppressWebViewFocus: () -> Bool
}

@MainActor
final class OmnibarTextFieldNativeHost {
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var configuration: OmnibarTextFieldNativeConfiguration
        var isProgrammaticMutation: Bool = false
        var selectionObserver: NSObjectProtocol?
        weak var observedEditor: NSTextView?
        var appliedInlineCompletion: OmnibarInlineCompletion?
        var lastPublishedSelection: NSRange = NSRange(location: NSNotFound, length: 0)
        var lastPublishedHasMarkedText: Bool = false
        /// Guards against infinite focus loops: `true` = focus requested, `false` = blur requested, `nil` = idle.
        var pendingFocusRequest: Bool?
        var pendingSelectAllRequestId: UInt64?
        var appliedSelectAllRequestId: UInt64 = 0

        init(configuration: OmnibarTextFieldNativeConfiguration) {
            self.configuration = configuration
        }

#if DEBUG
        func logFocusEvent(_ event: String, detail: String = "") {
            let window = parentField?.window
            let responder = window?.firstResponder
            let responderType = responder.map { String(describing: type(of: $0)) } ?? "nil"
            let responderIsField: Int = {
                guard let field = parentField else { return 0 }
                if responder === field { return 1 }
                if let editor = responder as? NSTextView,
                   (editor.delegate as? NSTextField) === field {
                    return 1
                }
                return 0
            }()
            let pendingValue: String = {
                guard let pendingFocusRequest else { return "nil" }
                return pendingFocusRequest ? "focus" : "blur"
            }()
            var line =
                "browser.focus.field event=\(event) focused=\(configuration.isFocused ? 1 : 0) " +
                "pending=\(pendingValue) suppressWeb=\(configuration.shouldSuppressWebViewFocus() ? 1 : 0) " +
                "win=\(window?.windowNumber ?? -1) fr=\(responderType) frIsField=\(responderIsField)"
            if !detail.isEmpty {
                line += " \(detail)"
            }
            cmuxDebugLog(line)
        }
#endif

        deinit {
            if let selectionObserver {
                NotificationCenter.default.removeObserver(selectionObserver)
            }
        }

        private func nextResponderIsOtherTextField(window: NSWindow?) -> Bool {
            guard let window, let field = parentField else { return false }
            let responder = window.firstResponder

            if let editor = responder as? NSTextView,
               let delegateField = editor.delegate as? NSTextField {
                return delegateField !== field
            }

            if let textField = responder as? NSTextField {
                return textField !== field
            }

            return false
        }

        private func isPointerDownEvent(_ event: NSEvent) -> Bool {
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                return true
            default:
                return false
            }
        }

        private func topHitViewForCurrentPointerEvent(window: NSWindow) -> NSView? {
            guard let event = NSApp.currentEvent, isPointerDownEvent(event) else {
                return nil
            }
            if event.windowNumber != 0, event.windowNumber != window.windowNumber {
                return nil
            }
            if let eventWindow = event.window, eventWindow !== window {
                return nil
            }

            if let contentView = window.contentView,
               let themeFrame = contentView.superview {
                let pointInTheme = themeFrame.convert(event.locationInWindow, from: nil)
                if let hitInTheme = themeFrame.hitTest(pointInTheme) {
                    return hitInTheme
                }
            }

            guard let contentView = window.contentView else {
                return nil
            }
            let pointInContent = contentView.convert(event.locationInWindow, from: nil)
            return contentView.hitTest(pointInContent)
        }

        private func pointerDownBlurIntent(window: NSWindow?) -> Bool {
            guard let window, let field = parentField else { return false }
            guard let hitView = topHitViewForCurrentPointerEvent(window: window) else {
                return false
            }

            if hitView === field || hitView.isDescendant(of: field) {
                return false
            }
            if let interactionView = hitView as? BrowserOmnibarInteractionView,
               MainActor.assumeIsolated({ interactionView.panelId == field.panelId }) {
                return false
            }
            if let textView = hitView as? NSTextView,
               let delegateField = textView.delegate as? NSTextField,
               delegateField === field {
                return false
            }
            return true
        }

        private func shouldReacquireFocusAfterEndEditing(window: NSWindow?) -> Bool {
            if parentField?.suppressNextFocusReacquireOnEndEditing == true {
                return false
            }
            if pointerDownBlurIntent(window: window) {
                return false
            }
            return browserOmnibarShouldReacquireFocusAfterEndEditing(
                desiredOmnibarFocus: configuration.isFocused,
                nextResponderIsOtherTextField: nextResponderIsOtherTextField(window: window)
            )
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
#if DEBUG
            logFocusEvent("controlTextDidBeginEditing")
#endif
            if !configuration.isFocused {
                Task { @MainActor [weak self] in
                    await Task.yield()
                    guard let self else { return }
#if DEBUG
                    self.logFocusEvent("controlTextDidBeginEditing.asyncSetFocused", detail: "old=0 new=1")
#endif
                    self.configuration.onFocusChange(true)
                }
            }
            attachSelectionObserverIfNeeded()
            if let field = obj.object as? OmnibarNativeTextField {
                field.suppressNextFocusReacquireOnEndEditing = false
                applyPendingSelectAllIfPossible(field: field)
            }
            publishSelectionState()
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            let shouldReacquire = shouldReacquireFocusAfterEndEditing(window: parentField?.window)
#if DEBUG
            let nextOther = nextResponderIsOtherTextField(window: parentField?.window)
            let pointerBlur = pointerDownBlurIntent(window: parentField?.window)
            logFocusEvent(
                "controlTextDidEndEditing",
                detail: "nextOther=\(nextOther ? 1 : 0) pointerBlur=\(pointerBlur ? 1 : 0) shouldReacquire=\(shouldReacquire ? 1 : 0)"
            )
#endif
            if configuration.isFocused {
                if shouldReacquire {
#if DEBUG
                    logFocusEvent("controlTextDidEndEditing.reacquire.begin")
#endif
                    guard pendingFocusRequest != true else { return }
                    pendingFocusRequest = true
                    Task { @MainActor [weak self] in
                        await Task.yield()
                        guard let self else { return }
                        self.pendingFocusRequest = nil
#if DEBUG
                        self.logFocusEvent("controlTextDidEndEditing.reacquire.tick")
#endif
                        guard self.configuration.isFocused else { return }
                        guard let field = self.parentField, let window = field.window else { return }
                        guard self.shouldReacquireFocusAfterEndEditing(window: window) else {
#if DEBUG
                            self.logFocusEvent("controlTextDidEndEditing.reacquire.cancel")
#endif
                            self.configuration.onFieldLostFocus()
                            return
                        }
                        // Check both the field itself AND its field editor (which becomes
                        // the actual first responder when the text field is being edited).
                        let fr = window.firstResponder
                        let isAlreadyFocused = fr === field ||
                            field.currentEditor() != nil ||
                            ((fr as? NSTextView)?.delegate as? NSTextField) === field
                        if !isAlreadyFocused {
#if DEBUG
                            self.logFocusEvent("controlTextDidEndEditing.reacquire.apply")
#endif
                            window.makeFirstResponder(field)
                        } else {
#if DEBUG
                            self.logFocusEvent("controlTextDidEndEditing.reacquire.skip", detail: "reason=already_focused")
#endif
                        }
                    }
                    return
                }
#if DEBUG
                logFocusEvent("controlTextDidEndEditing.blur")
#endif
                configuration.onFieldLostFocus()
            }
            parentField?.suppressNextFocusReacquireOnEndEditing = false
            detachSelectionObserver()
        }

        func controlTextDidChange(_ obj: Notification) {
#if DEBUG
            let typingTimingStart = CmuxTypingTiming.start()
            defer {
                CmuxTypingTiming.logDuration(
                    path: "browser.omnibar.controlTextDidChange",
                    startedAt: typingTimingStart,
                    event: NSApp.currentEvent,
                    extra: "programmatic=\(isProgrammaticMutation ? 1 : 0)"
                )
            }
#endif
            guard !isProgrammaticMutation else { return }
            guard let field = obj.object as? NSTextField else { return }
            let editor = field.currentEditor() as? NSTextView
            publishSelectionState()
            configuration.onTextChange(omnibarPublishedBufferTextForFieldChange(
                fieldValue: field.stringValue,
                inlineCompletion: configuration.inlineCompletion,
                selectionRange: editor?.selectedRange(),
                hasMarkedText: editor?.hasMarkedText() ?? false
            ))
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
#if DEBUG
            let typingTimingStart = CmuxTypingTiming.start()
            var handled = false
            defer {
                CmuxTypingTiming.logDuration(
                    path: "browser.omnibar.doCommandBy",
                    startedAt: typingTimingStart,
                    event: NSApp.currentEvent,
                    extra: "handled=\(handled ? 1 : 0) selector=\(NSStringFromSelector(commandSelector))"
                )
            }
#endif
            guard !textView.hasMarkedText() else { return false }
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)):
                configuration.onMoveSelection(+1)
#if DEBUG
                handled = true
#endif
                return true
            case #selector(NSResponder.moveUp(_:)):
                configuration.onMoveSelection(-1)
#if DEBUG
                handled = true
#endif
                return true
            case #selector(NSResponder.insertNewline(_:)):
                let currentFlags = NSApp.currentEvent?.modifierFlags ?? []
                guard browserOmnibarShouldSubmitOnReturn(flags: currentFlags) else { return false }
                configuration.onSubmit(liveFieldSnapshot(preferredEditor: textView))
#if DEBUG
                handled = true
#endif
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                configuration.onEscape()
#if DEBUG
                handled = true
#endif
                return true
            case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveToEndOfLine(_:)):
                if configuration.inlineCompletion != nil {
                    configuration.onAcceptInlineCompletion()
#if DEBUG
                    handled = true
#endif
                    return true
                }
                return false
            case #selector(NSResponder.insertTab(_:)):
                if configuration.inlineCompletion != nil {
                    configuration.onAcceptInlineCompletion()
#if DEBUG
                    handled = true
#endif
                    return true
                }
                return false
            case #selector(NSResponder.deleteBackward(_:)):
                if suffixSelectionMatchesInline(textView, inline: configuration.inlineCompletion) {
                    configuration.onDeleteBackwardWithInlineSelection()
#if DEBUG
                    handled = true
#endif
                    return true
                }
                return false
            case #selector(NSResponder.deleteToBeginningOfLine(_:)),
                 #selector(NSResponder.deleteToBeginningOfParagraph(_:)):
                if inlineCompletionSelectionIsActive(textView, inline: configuration.inlineCompletion) {
                    configuration.onClearTypedPrefixWithInlineSelection()
#if DEBUG
                    handled = true
#endif
                    return true
                }
                return false
            case #selector(NSResponder.deleteWordBackward(_:)):
                if inlineCompletionSelectionIsActive(textView, inline: configuration.inlineCompletion) {
                    configuration.onDeleteWordBackwardWithInlineSelection()
#if DEBUG
                    handled = true
#endif
                    return true
                }
                return false
            default:
                return false
            }
        }

        func attachSelectionObserverIfNeeded() {
            guard selectionObserver == nil else { return }
            guard let field = parentField else { return }
            guard let editor = field.currentEditor() as? NSTextView else { return }
            observedEditor = editor
            selectionObserver = NotificationCenter.default.addObserver(
                forName: NSTextView.didChangeSelectionNotification,
                object: editor,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.publishSelectionState()
                }
            }
        }

        func detachSelectionObserver() {
            if let selectionObserver {
                NotificationCenter.default.removeObserver(selectionObserver)
                self.selectionObserver = nil
            }
            observedEditor = nil
        }

        weak var parentField: OmnibarNativeTextField?

        func queueSelectAllRequest(_ requestId: UInt64) {
            guard requestId != 0, appliedSelectAllRequestId != requestId else { return }
            pendingSelectAllRequestId = requestId
        }

        @discardableResult
        func applyPendingSelectAllIfPossible(
            field: OmnibarNativeTextField
        ) -> Bool {
            guard let requestId = pendingSelectAllRequestId,
                  requestId != 0,
                  appliedSelectAllRequestId != requestId else {
                return false
            }

            guard let editor = field.currentEditor() as? NSTextView,
                  !editor.hasMarkedText() else {
                return false
            }
            let length = editor.string.utf16.count
            isProgrammaticMutation = true
            editor.setSelectedRange(NSRange(location: 0, length: length))
            isProgrammaticMutation = false
            appliedSelectAllRequestId = requestId
            pendingSelectAllRequestId = nil
            publishSelectionState()
            return true
        }

        func publishSelectionState() {
            guard let field = parentField else { return }
            if let editor = field.currentEditor() as? NSTextView {
                let range = editor.selectedRange()
                let hasMarkedText = editor.hasMarkedText()
                guard !NSEqualRanges(range, lastPublishedSelection) || hasMarkedText != lastPublishedHasMarkedText else {
                    return
                }
                lastPublishedSelection = range
                lastPublishedHasMarkedText = hasMarkedText
                configuration.onSelectionChanged(range, hasMarkedText)
            } else {
                let location = field.stringValue.utf16.count
                let range = NSRange(location: location, length: 0)
                guard !NSEqualRanges(range, lastPublishedSelection) || lastPublishedHasMarkedText else { return }
                lastPublishedSelection = range
                lastPublishedHasMarkedText = false
                configuration.onSelectionChanged(range, false)
            }
        }

        /// Captures the field-editor text synchronously at submit time. Both
        /// Return interception paths (`doCommandBy` and `handleKeyEvent`) go
        /// through here so the submit decision always starts from what the
        /// field actually shows, not the possibly lagging published state.
        private func liveFieldSnapshot(preferredEditor: NSTextView?) -> OmnibarLiveFieldSnapshot? {
            let editor = preferredEditor ?? (parentField?.currentEditor() as? NSTextView)
            if let editor {
                return OmnibarLiveFieldSnapshot(
                    text: editor.string,
                    selectionRange: editor.selectedRange(),
                    hasMarkedText: editor.hasMarkedText()
                )
            }
            guard let field = parentField else { return nil }
            return OmnibarLiveFieldSnapshot(
                text: field.stringValue,
                selectionRange: nil,
                hasMarkedText: false
            )
        }

        private func inlineCompletionSelectionIsActive(_ editor: NSTextView?, inline: OmnibarInlineCompletion?) -> Bool {
            suffixSelectionMatchesInline(editor, inline: inline) || selectionIsTypedPrefixBoundary(editor, inline: inline)
        }

        private func suffixSelectionMatchesInline(_ editor: NSTextView?, inline: OmnibarInlineCompletion?) -> Bool {
            guard let editor, let inline else { return false }
            let selected = editor.selectedRange()
            return NSEqualRanges(selected, inline.suffixRange)
        }

        private func selectionIsTypedPrefixBoundary(_ editor: NSTextView?, inline: OmnibarInlineCompletion?) -> Bool {
            guard let editor, let inline else { return false }
            let selected = editor.selectedRange()
            let typedCount = inline.typedText.utf16.count
            return selected.location == typedCount && selected.length == 0
        }

        func handleKeyEvent(_ event: NSEvent, editor: NSTextView?) -> Bool {
#if DEBUG
            let typingTimingStart = CmuxTypingTiming.start()
            var handled = false
            defer {
                CmuxTypingTiming.logDuration(
                    path: "browser.omnibar.handleKeyEvent",
                    startedAt: typingTimingStart,
                    event: event,
                    extra: "handled=\(handled ? 1 : 0)"
                )
            }
#endif
            // #6250: AppKit invokes `performKeyEquivalent` across the entire
            // window view hierarchy, so this coordinator runs even while web
            // content (the WKWebView) — not the omnibar — owns first responder.
            // In that state the omnibar field has no field editor, so `editor`
            // is nil. Treating Return/Escape/arrows (and Ctrl+N/P, Shift+Delete)
            // as omnibar input there makes an *unfocused* omnibar submit and
            // hard-navigate the pane on a physical Enter that belongs to the
            // page — a spurious reload that aborts in-flight `fetch`/XHR in SPAs.
            // Only act on these keys while the field is actually being edited.
            // This mirrors the `currentEditor()`-gated `insertNewline:` path in
            // `control(_:textView:doCommandBy:)`, which only runs for the live
            // field editor.
            guard editor != nil else { return false }
            guard editor?.hasMarkedText() != true else { return false }
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags.intersection([.command, .control, .shift, .option, .function])
            // When a non-Latin input source is active (Korean, Chinese, Japanese),
            // charactersIgnoringModifiers returns non-ASCII characters. Normalize
            // via KeyboardLayout so Ctrl+N/P navigation works across input sources.
            let lowered = KeyboardLayout.normalizedCharacters(for: event)

            // Ctrl+N and Ctrl+P should repeat while held.
            if let delta = browserOmnibarSelectionDeltaForControlNavigation(
                hasFocusedAddressBar: true,
                flags: event.modifierFlags,
                chars: lowered
            ) {
                configuration.onMoveSelection(delta)
#if DEBUG
                handled = true
#endif
                return true
            }

            // Shift+Delete removes the selected history suggestion when possible.
            if modifiers.contains(.shift), (keyCode == 51 || keyCode == 117) {
                configuration.onDeleteSelectedSuggestion()
#if DEBUG
                handled = true
#endif
                return true
            }

            switch keyCode {
            case 36, 76: // Return / keypad Enter
                guard browserOmnibarShouldSubmitOnReturn(flags: event.modifierFlags) else { return false }
                configuration.onSubmit(liveFieldSnapshot(preferredEditor: editor))
#if DEBUG
                handled = true
#endif
                return true
            case 53: // Escape
                configuration.onEscape()
#if DEBUG
                handled = true
#endif
                return true
            case 125: // Down
                configuration.onMoveSelection(+1)
#if DEBUG
                handled = true
#endif
                return true
            case 126: // Up
                configuration.onMoveSelection(-1)
#if DEBUG
                handled = true
#endif
                return true
            case 124, 119: // Right arrow / End
                if configuration.inlineCompletion != nil {
                    configuration.onAcceptInlineCompletion()
#if DEBUG
                    handled = true
#endif
                    return true
                }
            case 48: // Tab
                if configuration.inlineCompletion != nil {
                    configuration.onAcceptInlineCompletion()
#if DEBUG
                    handled = true
#endif
                    return true
                }
            case 51: // Backspace
                if modifiers.contains(.command) || modifiers.contains(.option) {
                    return false
                }
                if let inline = configuration.inlineCompletion,
                   inlineCompletionSelectionIsActive(editor, inline: inline) {
                    configuration.onDeleteBackwardWithInlineSelection()
#if DEBUG
                    handled = true
#endif
                    return true
                }
            default:
                break
            }

            return false
        }
    }

    let field: OmnibarNativeTextField
    private let coordinator: Coordinator

    init(configuration: OmnibarTextFieldNativeConfiguration) {
        coordinator = Coordinator(configuration: configuration)
        field = configuration.makeNativeField(coordinator: coordinator)
    }

    func update(_ configuration: OmnibarTextFieldNativeConfiguration) {
        configuration.updateNativeField(field, coordinator: coordinator)
    }

    func teardown() {
        OmnibarTextFieldNativeConfiguration.dismantleNativeField(field, coordinator: coordinator)
    }
}

extension OmnibarTextFieldNativeConfiguration {
    func makeNativeField(coordinator: OmnibarTextFieldNativeHost.Coordinator) -> OmnibarNativeTextField {
        let field = OmnibarNativeTextField(frame: .zero)
        field.panelId = panelId
        BrowserOmnibarNativeFieldRegistry.shared.register(field, panelId: panelId)
        field.identifier = browserOmnibarTextFieldIdentifier
        field.font = .systemFont(ofSize: fontSize)
        field.placeholderString = placeholder
        field.delegate = coordinator
        field.target = nil
        field.action = nil
        field.isEditable = true
        field.isSelectable = true
        field.isEnabled = true
        field.stringValue = text
        field.onPointerDown = {
            onTap()
        }
        field.onHandleKeyEvent = { [weak coordinator] event, editor in
            coordinator?.handleKeyEvent(event, editor: editor) ?? false
        }
        coordinator.parentField = field
        BrowserOmnibarNativeFieldRegistry.shared.register(field, panelId: panelId)
        return field
    }

    func updateNativeField(
        _ nsView: OmnibarNativeTextField,
        coordinator: OmnibarTextFieldNativeHost.Coordinator
    ) {
        coordinator.configuration = self
        coordinator.parentField = nsView
        if let previousPanelId = nsView.panelId, previousPanelId != panelId {
            BrowserOmnibarNativeFieldRegistry.shared.unregister(nsView, panelId: previousPanelId)
        }
        nsView.panelId = panelId
        BrowserOmnibarNativeFieldRegistry.shared.register(nsView, panelId: panelId)
        nsView.placeholderString = placeholder
        if nsView.font?.pointSize != fontSize {
            nsView.font = .systemFont(ofSize: fontSize)
        }
        coordinator.queueSelectAllRequest(selectAllRequestId)

        let activeInlineCompletion = omnibarInlineCompletionIfBufferMatchesTypedPrefix(
            bufferText: text,
            inlineCompletion: inlineCompletion
        )
        let desiredDisplayText = activeInlineCompletion?.displayText ?? text
        if let editor = nsView.currentEditor() as? NSTextView {
            if !editor.hasMarkedText(), editor.string != desiredDisplayText {
                coordinator.isProgrammaticMutation = true
                editor.string = desiredDisplayText
                nsView.stringValue = desiredDisplayText
                coordinator.isProgrammaticMutation = false
            }
        } else if nsView.stringValue != desiredDisplayText {
            nsView.stringValue = desiredDisplayText
        }

        if let window = nsView.window {
            let firstResponder = window.firstResponder
            let isFirstResponder =
                firstResponder === nsView ||
                nsView.currentEditor() != nil ||
                ((firstResponder as? NSTextView)?.delegate as? NSTextField) === nsView
            if isFocused, !isFirstResponder, coordinator.pendingFocusRequest != true {
#if DEBUG
                coordinator.logFocusEvent(
                    "updateNSView.requestFocus.begin",
                    detail: "isFocused=1 isFirstResponder=0"
                )
#endif
                // Defer to avoid triggering input method XPC during layout pass,
                // which can crash via re-entrant view hierarchy modification.
                coordinator.pendingFocusRequest = true
                Task { @MainActor [weak nsView, weak coordinator] in
                    await Task.yield()
                    coordinator?.pendingFocusRequest = nil
                    guard let nsView, let window = nsView.window else { return }
#if DEBUG
                    if coordinator?.configuration.isFocused != true {
                        coordinator?.logFocusEvent("updateNSView.requestFocus.cancel", detail: "reason=stale_state")
                        return
                    }
#endif
                    guard coordinator?.configuration.isFocused == true else { return }
#if DEBUG
                    coordinator?.logFocusEvent("updateNSView.requestFocus.tick")
#endif
                    let fr = window.firstResponder
                    let alreadyFocused = fr === nsView ||
                        nsView.currentEditor() != nil ||
                        ((fr as? NSTextView)?.delegate as? NSTextField) === nsView
                    if alreadyFocused {
                        coordinator?.applyPendingSelectAllIfPossible(field: nsView)
                        return
                    }
#if DEBUG
                    coordinator?.logFocusEvent("updateNSView.requestFocus.apply")
#endif
                    window.makeFirstResponder(nsView)
                    coordinator?.applyPendingSelectAllIfPossible(field: nsView)
                }
            } else if !isFocused, isFirstResponder, coordinator.pendingFocusRequest != false {
#if DEBUG
                coordinator.logFocusEvent(
                    "updateNSView.requestBlur.begin",
                    detail: "isFocused=0 isFirstResponder=1"
                )
#endif
                coordinator.pendingFocusRequest = false
                Task { @MainActor [weak nsView, weak coordinator] in
                    await Task.yield()
                    coordinator?.pendingFocusRequest = nil
                    guard let nsView, let window = nsView.window else { return }
#if DEBUG
                    if coordinator?.configuration.isFocused == true {
                        coordinator?.logFocusEvent("updateNSView.requestBlur.cancel", detail: "reason=stale_state")
                        return
                    }
#endif
                    guard coordinator?.configuration.isFocused == false else { return }
#if DEBUG
                    coordinator?.logFocusEvent("updateNSView.requestBlur.tick")
#endif
                    let fr = window.firstResponder
                    let stillFirst = fr === nsView ||
                        ((fr as? NSTextView)?.delegate as? NSTextField) === nsView
                    guard stillFirst else { return }
#if DEBUG
                    coordinator?.logFocusEvent("updateNSView.requestBlur.apply")
#endif
                    window.makeFirstResponder(nil)
                }
            }
        }
        coordinator.applyPendingSelectAllIfPossible(field: nsView)

        if let editor = nsView.currentEditor() as? NSTextView, !editor.hasMarkedText() {
            if let activeInlineCompletion {
                let currentSelection = editor.selectedRange()
                let desiredSelection = omnibarDesiredSelectionRangeForInlineCompletion(
                    currentSelection: currentSelection,
                    inlineCompletion: activeInlineCompletion
                )
                if coordinator.appliedInlineCompletion != activeInlineCompletion ||
                    !NSEqualRanges(currentSelection, desiredSelection) {
                    coordinator.isProgrammaticMutation = true
                    editor.setSelectedRange(desiredSelection)
                    coordinator.isProgrammaticMutation = false
                }
            } else if coordinator.appliedInlineCompletion != nil {
                let end = text.utf16.count
                let current = editor.selectedRange()
                if current.length != 0 || current.location != end {
                    coordinator.isProgrammaticMutation = true
                    editor.setSelectedRange(NSRange(location: end, length: 0))
                    coordinator.isProgrammaticMutation = false
                }
            }
        }
        coordinator.appliedInlineCompletion = activeInlineCompletion
        coordinator.attachSelectionObserverIfNeeded()
        coordinator.publishSelectionState()
    }

    static func dismantleNativeField(
        _ nsView: OmnibarNativeTextField,
        coordinator: OmnibarTextFieldNativeHost.Coordinator
    ) {
        if let panelId = nsView.panelId {
            BrowserOmnibarNativeFieldRegistry.shared.unregister(nsView, panelId: panelId)
        }
        nsView.onPointerDown = nil
        nsView.onHandleKeyEvent = nil
        nsView.delegate = nil
        coordinator.detachSelectionObserver()
        coordinator.parentField = nil
    }
}

@MainActor
func browserOmnibarPanelId(for responder: NSResponder?) -> UUID? {
    browserOmnibarField(for: responder)?.panelId
}

@MainActor
func browserOmnibarField(panelId: UUID?, in window: NSWindow?) -> OmnibarNativeTextField? {
    if let registeredField = BrowserOmnibarNativeFieldRegistry.shared.field(for: panelId, in: window) {
        return registeredField
    }
    guard let panelId, let root = window?.contentView?.superview ?? window?.contentView else {
        return nil
    }

    // Fallback for native host reconnect windows where the live field
    // has been attached but registration has not yet observed it.
    var stack: [NSView] = [root]
    while let view = stack.popLast() {
        if let field = view as? OmnibarNativeTextField, field.panelId == panelId {
            return field
        }
        stack.append(contentsOf: view.subviews)
    }
    return nil
}

@discardableResult
@MainActor
func browserPrepareOmnibarForProgrammaticBlur(panelId: UUID, responder: NSResponder?) -> Bool {
    guard let field = browserOmnibarField(for: responder),
          field.panelId == panelId else {
        return false
    }
    field.suppressNextFocusReacquireOnEndEditing = true
    return true
}

@MainActor
private func browserOmnibarField(for responder: NSResponder?) -> OmnibarNativeTextField? {
    guard let responder else { return nil }

    if let field = responder as? OmnibarNativeTextField {
        return field
    }

    if let editor = responder as? NSTextView, editor.isFieldEditor {
        if let field = BrowserOmnibarNativeFieldRegistry.shared.fieldOwningEditor(editor, in: editor.window) {
            return field
        }

        if let field = cmuxFieldEditorOwnerView(editor) as? OmnibarNativeTextField,
           field.currentEditor() === editor {
            return field
        }

    }

    return nil
}

/// Native AppKit host for WKWebView
@MainActor
struct BrowserWebViewNativeConfiguration {
    let panel: BrowserPanel
    let paneId: PaneID
    let shouldAttachWebView: Bool
    let useLocalInlineHosting: Bool
    let shouldFocusWebView: Bool
    let isPanelFocused: Bool
    let portalZPriority: Int
    let paneDropZone: DropZone?
    /// Explicit pane-ownership for hosts (the Dock) whose panels are not in the
    /// main `Workspace` tree, so the portal-visibility gate can resolve ownership
    /// without `Workspace.paneId(forPanelId:)`. `nil` keeps the main-area path.
    var paneOwnershipOverride: Bool? = nil
    let searchOverlay: BrowserPortalSearchOverlayConfiguration?
    let designComposer: BrowserPortalDesignComposerConfiguration?
    let omnibarSuggestions: BrowserPortalOmnibarSuggestionsConfiguration?
    let paneTopChromeHeight: CGFloat

    final class Coordinator {
        weak var panel: BrowserPanel?
        weak var webView: WKWebView?
        var attachGeneration: Int = 0
        var desiredPortalVisibleInUI: Bool = true
        var desiredPortalZPriority: Int = 0
        var lastPortalHostId: ObjectIdentifier?
        var lastSynchronizedHostGeometryRevision: UInt64 = 0
    }

    @MainActor
    final class NativeHost {
        let view = HostContainerView(frame: .zero)
        private let coordinator = Coordinator()

        init() {
            view.wantsLayer = true
        }

        func update(_ configuration: BrowserWebViewNativeConfiguration) {
            configuration.updateNativeView(view, coordinator: coordinator)
        }

        func teardown() {
            BrowserWebViewNativeConfiguration.dismantleNativeView(view, coordinator: coordinator)
        }
    }

    final class HostContainerView: NSView {
        private final class HostedInspectorSideDockContainerView: NSView {
            override init(frame frameRect: NSRect) {
                super.init(frame: frameRect)
                wantsLayer = true
                layer?.masksToBounds = true
            }

            @available(*, unavailable)
            required init?(coder: NSCoder) {
                nil
            }

            override var isOpaque: Bool { false }

            override func resizeSubviews(withOldSize oldSize: NSSize) {
                // Managed side-docked DevTools use explicit frame updates from the host.
                // Letting AppKit autoresize the WK siblings here makes them snap back to
                // stale widths while the divider drag or pane resize is in flight.
            }
        }

        var onDidMoveToWindow: (() -> Void)?
        var onGeometryChanged: (() -> Void)?
        private(set) var geometryRevision: UInt64 = 0
        private var lastReportedGeometryState: GeometryState?
        private var hasPendingGeometryNotification = false
        private weak var hostedWebView: WKWebView?
        private var hostedWebViewConstraints: [NSLayoutConstraint] = []
        private weak var localInlineSlotView: WindowBrowserSlotView?
        private var localInlineSlotConstraints: [NSLayoutConstraint] = []
        private weak var hostedInspectorSideDockContainerView: HostedInspectorSideDockContainerView?
        private var hostedInspectorSideDockConstraints: [NSLayoutConstraint] = []
        private weak var hostedInspectorFrontendWebView: WKWebView?
        private struct HostedInspectorDividerHit {
            let containerView: NSView
            let pageView: NSView
            let inspectorView: NSView
            let dockSide: HostedInspectorDockSide
        }

        private struct GeometryState: Equatable {
            let frame: CGRect
            let bounds: CGRect
            let windowNumber: Int?
            let superviewID: ObjectIdentifier?
        }

        private struct HostedInspectorDividerDragState {
            let containerView: NSView
            let pageView: NSView
            let inspectorView: NSView
            let dockSide: HostedInspectorDockSide
            let initialWindowX: CGFloat
            let initialPageFrame: NSRect
            let initialInspectorFrame: NSRect
        }


        private static let hostedInspectorDividerHitExpansion: CGFloat = 10
        private static let minimumHostedInspectorWidth: CGFloat = 120
        private static let minimumHostedInspectorPageWidthForSideDock: CGFloat = 240
        private static let adaptiveBottomDockRequestCooldown: TimeInterval = 0.25
        private var trackingArea: NSTrackingArea?
        private var activeDividerCursorKind: PortalDividerCursorKind?
        private let dividerCursorOcclusion = PortalDividerCursorOcclusion()
        private var hostedInspectorDividerDrag: HostedInspectorDividerDragState?
        private var preferredHostedInspectorWidth: CGFloat?
        private var preferredHostedInspectorWidthFraction: CGFloat?
        var onPreferredHostedInspectorWidthChanged: ((CGFloat, CGFloat?) -> Void)?
        private weak var hostedInspectorSideDockPageView: NSView?
        private weak var hostedInspectorSideDockInspectorView: NSView?
        private var hostedInspectorSideDockDockSide: HostedInspectorDockSide?
        private var isHostedInspectorDividerDragActive = false
        private var isApplyingHostedInspectorLayout = false
        private let hostedInspectorReapplyScheduler = MainActorDeferredActionScheduler()
        private let hostedInspectorDockConfigurationSyncScheduler = MainActorDeferredActionScheduler()
        private var hostedInspectorSideDockPromotionTask: Task<Void, Never>?
        private var hostedInspectorSideDockPromotionTaskID: UUID?
        private var adaptiveBottomDockRequestCooldownDeadline: Date?
        private var recordedHostedInspectorSideDockWidth: CGFloat?
        private var lastHostedInspectorManualSideDockAllowed: Bool?
        private var lastHostedInspectorDetachedFromHostWindow: Bool?
        private var lastHostedInspectorLayoutBoundsSize: NSSize?
#if DEBUG
        private var lastLoggedHostedInspectorFrames: (page: NSRect, inspector: NSRect)?
        private var hasLoggedMissingHostedInspectorCandidate = false
#endif

        deinit {
            hostedInspectorSideDockPromotionTask?.cancel()
            if let trackingArea {
                removeTrackingArea(trackingArea)
            }
            clearActiveDividerCursor(restoreArrow: false)
        }

        private func recordPreferredHostedInspectorWidth(_ width: CGFloat, containerBounds: NSRect) {
            preferredHostedInspectorWidth = width
            guard containerBounds.width > 0 else {
                preferredHostedInspectorWidthFraction = nil
                onPreferredHostedInspectorWidthChanged?(width, nil)
                return
            }
            preferredHostedInspectorWidthFraction = width / containerBounds.width
            onPreferredHostedInspectorWidthChanged?(width, preferredHostedInspectorWidthFraction)
        }

        private func resolvedPreferredHostedInspectorWidth(in containerBounds: NSRect) -> CGFloat? {
            if let preferredHostedInspectorWidthFraction, containerBounds.width > 0 {
                return max(0, containerBounds.width * preferredHostedInspectorWidthFraction)
            }
            return preferredHostedInspectorWidth
        }

        func setPreferredHostedInspectorWidth(width: CGFloat?, widthFraction: CGFloat?) {
            preferredHostedInspectorWidth = width
            preferredHostedInspectorWidthFraction = widthFraction
        }

        private func recordHostedInspectorSideDockWidth(_ width: CGFloat) {
            guard width > 1 else { return }
            recordedHostedInspectorSideDockWidth = max(Self.minimumHostedInspectorWidth, width)
        }

        private func shouldAllowHostedInspectorManualSideDock() -> Bool {
            let containerWidth = max(0, bounds.width)
            guard containerWidth > 1 else { return true }
            let baselineWidth = max(
                Self.minimumHostedInspectorWidth,
                recordedHostedInspectorSideDockWidth ?? Self.minimumHostedInspectorWidth
            )
            return containerWidth - baselineWidth >= Self.minimumHostedInspectorPageWidthForSideDock
        }

        private func updateHostedInspectorDockControlAvailabilityIfNeeded(reason: String) {
            guard let hostedInspectorFrontendWebView else {
                lastHostedInspectorManualSideDockAllowed = nil
                lastHostedInspectorDetachedFromHostWindow = nil
                return
            }

            let sideDockAllowed = shouldAllowHostedInspectorManualSideDock()
            let detachedFromHostWindow =
                hostedInspectorFrontendWebView.window != nil &&
                hostedInspectorFrontendWebView.window !== window
            guard lastHostedInspectorManualSideDockAllowed != sideDockAllowed ||
                lastHostedInspectorDetachedFromHostWindow != detachedFromHostWindow else {
                return
            }

#if DEBUG
            let recordedWidthDesc = recordedHostedInspectorSideDockWidth.map {
                String(format: "%.1f", $0)
            } ?? "nil"
            cmuxDebugLog(
                "browser.panel.hostedInspector stage=\(reason).dockControls " +
                "host=\(Self.debugObjectID(self)) allowSideDock=\(sideDockAllowed ? 1 : 0) " +
                "detachedFromHostWindow=\(detachedFromHostWindow ? 1 : 0) " +
                "recordedWidth=\(recordedWidthDesc) bounds=\(Self.debugRect(bounds))"
            )
#endif
            hostedInspectorFrontendWebView.evaluateJavaScript(
                HostedInspectorDockControlScript(
                    allowSideDock: sideDockAllowed,
                    detachedFromHostWindow: detachedFromHostWindow
                ).source,
                completionHandler: { [weak self, weak hostedInspectorFrontendWebView] result, error in
                    guard let self,
                          self.hostedInspectorFrontendWebView === hostedInspectorFrontendWebView else {
                        return
                    }
                    guard error == nil, result != nil, !(result is NSNull) else {
                        self.lastHostedInspectorManualSideDockAllowed = nil
                        self.lastHostedInspectorDetachedFromHostWindow = nil
                        return
                    }
                    self.lastHostedInspectorManualSideDockAllowed = sideDockAllowed
                    self.lastHostedInspectorDetachedFromHostWindow = detachedFromHostWindow
                }
            )
        }

        func containsManagedLocalInlineContent(_ view: NSView) -> Bool {
            if let localInlineSlotView,
               view === localInlineSlotView || view.isDescendant(of: localInlineSlotView) {
                return true
            }
            if let hostedInspectorSideDockContainerView,
               view === hostedInspectorSideDockContainerView || view.isDescendant(of: hostedInspectorSideDockContainerView) {
                return true
            }
            return false
        }

        func currentHostedWebViewContainer(preferredSlotView: WindowBrowserSlotView) -> NSView {
            if let hostedInspectorSideDockContainerView,
               let hostedInspectorSideDockPageView,
               hostedWebView?.isDescendant(of: hostedInspectorSideDockContainerView) == true,
               hostedInspectorSideDockPageView.isDescendant(of: hostedInspectorSideDockContainerView) {
                return hostedInspectorSideDockContainerView
            }
            return preferredSlotView
        }

        func setHostedInspectorFrontendWebView(_ webView: WKWebView?) {
            hostedInspectorFrontendWebView = webView
            lastHostedInspectorManualSideDockAllowed = nil
            lastHostedInspectorDetachedFromHostWindow = nil
            updateHostedInspectorDockControlAvailabilityIfNeeded(reason: "setHostedInspectorFrontendWebView")
        }

        private var hasStoredHostedInspectorWidthPreference: Bool {
            preferredHostedInspectorWidth != nil || preferredHostedInspectorWidthFraction != nil
        }

#if DEBUG
        private static func shouldLogPointerEvent(_ event: NSEvent?) -> Bool {
            switch event?.type {
            case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
                return true
            default:
                return false
            }
        }

        private func debugLogHitTest(stage: String, point: NSPoint, passThrough: Bool, hitView: NSView?) {
            let event = NSApp.currentEvent
            guard Self.shouldLogPointerEvent(event) else { return }

            let hitDesc: String = {
                guard let hitView else { return "nil" }
                let token = Unmanaged.passUnretained(hitView).toOpaque()
                return "\(type(of: hitView))@\(token)"
            }()
            let hostRectInContent: NSRect = {
                guard let window, let contentView = window.contentView else { return .zero }
                return contentView.convert(bounds, from: self)
            }()
            cmuxDebugLog(
                "browser.panel.host stage=\(stage) event=\(String(describing: event?.type)) " +
                "point=\(String(format: "%.1f,%.1f", point.x, point.y)) pass=\(passThrough ? 1 : 0) " +
                "hostFrameInContent=\(String(format: "%.1f,%.1f %.1fx%.1f", hostRectInContent.origin.x, hostRectInContent.origin.y, hostRectInContent.width, hostRectInContent.height)) " +
                "hit=\(hitDesc)"
            )
        }

        private static func debugObjectID(_ object: AnyObject?) -> String {
            guard let object else { return "nil" }
            return String(describing: Unmanaged.passUnretained(object).toOpaque())
        }

        private static func debugRect(_ rect: NSRect) -> String {
            String(format: "%.1f,%.1f %.1fx%.1f", rect.origin.x, rect.origin.y, rect.width, rect.height)
        }

        private func debugLogHostedInspectorFrames(
            stage: String,
            point: NSPoint? = nil,
            hit: HostedInspectorDividerHit
        ) {
            let pointDesc = point.map { String(format: "%.1f,%.1f", $0.x, $0.y) } ?? "nil"
            let preferredWidthDesc = preferredHostedInspectorWidth.map { String(format: "%.1f", $0) } ?? "nil"
            cmuxDebugLog(
                "browser.panel.hostedInspector stage=\(stage) point=\(pointDesc) " +
                "host=\(Self.debugObjectID(self)) container=\(Self.debugObjectID(hit.containerView)) " +
                "page=\(Self.debugObjectID(hit.pageView)) inspector=\(Self.debugObjectID(hit.inspectorView)) " +
                "preferredWidth=\(preferredWidthDesc) " +
                "hostFrame=\(Self.debugRect(frame)) hostBounds=\(Self.debugRect(bounds)) " +
                "containerBounds=\(Self.debugRect(hit.containerView.bounds)) " +
                "pageFrame=\(Self.debugRect(hit.pageView.frame)) " +
                "inspectorFrame=\(Self.debugRect(hit.inspectorView.frame))"
            )
        }

        private func debugLogHostedInspectorLayoutIfNeeded(reason: String) {
            guard let hit = hostedInspectorDividerCandidate() else {
                if !hasLoggedMissingHostedInspectorCandidate,
                   lastLoggedHostedInspectorFrames != nil || preferredHostedInspectorWidth != nil {
                    let preferredWidthDesc = preferredHostedInspectorWidth.map {
                        String(format: "%.1f", $0)
                    } ?? "nil"
                    lastLoggedHostedInspectorFrames = nil
                    hasLoggedMissingHostedInspectorCandidate = true
                    cmuxDebugLog(
                        "browser.panel.hostedInspector stage=\(reason).candidateMissing " +
                        "host=\(Self.debugObjectID(self)) preferredWidth=\(preferredWidthDesc)"
                    )
                }
                return
            }
            hasLoggedMissingHostedInspectorCandidate = false

            let nextFrames = (page: hit.pageView.frame, inspector: hit.inspectorView.frame)
            if let lastLoggedHostedInspectorFrames,
               Self.rectApproximatelyEqual(lastLoggedHostedInspectorFrames.page, nextFrames.page),
               Self.rectApproximatelyEqual(lastLoggedHostedInspectorFrames.inspector, nextFrames.inspector) {
                return
            }

            lastLoggedHostedInspectorFrames = nextFrames
            debugLogHostedInspectorFrames(stage: "\(reason).layout", hit: hit)
        }
#endif

        private static func rectApproximatelyEqual(_ lhs: NSRect, _ rhs: NSRect, epsilon: CGFloat = 0.5) -> Bool {
            abs(lhs.origin.x - rhs.origin.x) <= epsilon &&
                abs(lhs.origin.y - rhs.origin.y) <= epsilon &&
                abs(lhs.width - rhs.width) <= epsilon &&
                abs(lhs.height - rhs.height) <= epsilon
        }

        private static func sizeApproximatelyEqual(_ lhs: NSSize, _ rhs: NSSize, epsilon: CGFloat = 0.5) -> Bool {
            abs(lhs.width - rhs.width) <= epsilon &&
                abs(lhs.height - rhs.height) <= epsilon
        }

        private func currentGeometryState() -> GeometryState {
            GeometryState(
                frame: frame,
                bounds: bounds,
                windowNumber: window?.windowNumber,
                superviewID: superview.map(ObjectIdentifier.init)
            )
        }

        /// Record that geometry changed without firing the callback immediately.
        /// `setFrameOrigin`/`setFrameSize` can fire multiple times before `layout()`;
        /// deferring avoids redundant portal-sync cascades during divider drag.
        /// A task fallback ensures the callback fires even if `layout()` is not called.
        /// Note: `lastReportedGeometryState` and `geometryRevision` are only updated
        /// when the callback actually fires, so `updateNSView` sees a revision that
        /// is strictly tied to emitted callbacks (no premature increments).
        private func markGeometryDirtyIfNeeded() {
            let state = currentGeometryState()
            guard state != lastReportedGeometryState else { return }
            guard !hasPendingGeometryNotification else { return }
            hasPendingGeometryNotification = true
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.notifyGeometryChangedIfNeeded()
            }
        }

        /// Check for geometry changes and fire the callback. Also flushes any pending
        /// dirty state from `markGeometryDirtyIfNeeded` so `layout()` supersedes the
        /// async fallback.  Only updates `lastReportedGeometryState` / `geometryRevision`
        /// when the callback is emitted, keeping the revision in sync with actual
        /// notifications.
        private func notifyGeometryChangedIfNeeded() {
            hasPendingGeometryNotification = false
            let state = currentGeometryState()
            guard state != lastReportedGeometryState else { return }
            lastReportedGeometryState = state
            geometryRevision &+= 1
            onGeometryChanged?()
        }

        func ensureLocalInlineSlotView() -> WindowBrowserSlotView {
            if let localInlineSlotView, localInlineSlotView.superview === self {
                localInlineSlotView.isHidden = false
                return localInlineSlotView
            }

            let slotView = WindowBrowserSlotView(frame: bounds)
            slotView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(slotView, positioned: .above, relativeTo: nil)
            localInlineSlotConstraints = [
                slotView.topAnchor.constraint(equalTo: topAnchor),
                slotView.bottomAnchor.constraint(equalTo: bottomAnchor),
                slotView.leadingAnchor.constraint(equalTo: leadingAnchor),
                slotView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ]
            NSLayoutConstraint.activate(localInlineSlotConstraints)
            localInlineSlotView = slotView
            return slotView
        }

#if DEBUG
        func localInlineSlotViewForDebug() -> WindowBrowserSlotView? {
            localInlineSlotView
        }
#endif

        func setLocalInlineSlotHidden(_ hidden: Bool) {
            localInlineSlotView?.isHidden = hidden
            if hidden {
                notifyHostedWebKitHidden(reason: "slotHidden")
            }
        }

        func clearLocalInlineCallbacks() {
            onPreferredHostedInspectorWidthChanged = nil
            localInlineSlotView?.onHostedInspectorLayout = nil
        }

        private func appendHostedWebKitSubviews(
            in root: NSView,
            to result: inout [WKWebView],
            seen: inout Set<ObjectIdentifier>
        ) {
            if let webView = root as? WKWebView {
                guard !cmuxIsWebInspectorObject(webView) else { return }
                let id = ObjectIdentifier(webView)
                if seen.insert(id).inserted {
                    result.append(webView)
                }
            }
            for subview in root.subviews {
                appendHostedWebKitSubviews(in: subview, to: &result, seen: &seen)
            }
        }

        private var hostedWebKitSubviews: [WKWebView] {
            var result: [WKWebView] = []
            var seen = Set<ObjectIdentifier>()

            func append(_ webView: WKWebView?) {
                guard let webView else { return }
                guard !cmuxIsWebInspectorObject(webView) else { return }
                let id = ObjectIdentifier(webView)
                guard seen.insert(id).inserted else { return }
                result.append(webView)
            }

            append(hostedWebView)
            appendHostedWebKitSubviews(in: self, to: &result, seen: &seen)
            return result
        }

        private func notifyHostedWebKitHidden(reason: String) {
            for webView in hostedWebKitSubviews {
                webView.browserPortalNotifyHidden(reason: reason)
            }
        }

        func refreshHostedWebKitPresentation(
            reason: String,
            forceLifecycleRefresh: Bool = false
        ) {
            guard let localInlineSlotView else { return }
            guard !localInlineSlotView.isHidden else { return }
            let hostedWebKitSubviews = hostedWebKitSubviews
            guard !hostedWebKitSubviews.isEmpty else { return }

            localInlineSlotView.needsLayout = true
            localInlineSlotView.needsDisplay = true
            localInlineSlotView.setNeedsDisplay(localInlineSlotView.bounds)

            needsLayout = true
            needsDisplay = true
            setNeedsDisplay(bounds)

            for webView in hostedWebKitSubviews {
                if let scrollView = webView.enclosingScrollView {
                    scrollView.needsLayout = true
                    scrollView.needsDisplay = true
                    scrollView.setNeedsDisplay(scrollView.bounds)
                    scrollView.contentView.needsLayout = true
                    scrollView.contentView.needsDisplay = true
                }
                webView.needsLayout = true
                webView.needsDisplay = true
                webView.setNeedsDisplay(webView.bounds)
            }

            localInlineSlotView.layoutSubtreeIfNeeded()
            layoutSubtreeIfNeeded()

            for webView in hostedWebKitSubviews {
                if let scrollView = webView.enclosingScrollView {
                    scrollView.layoutSubtreeIfNeeded()
                    scrollView.contentView.layoutSubtreeIfNeeded()
                    scrollView.displayIfNeeded()
                }
                webView.layoutSubtreeIfNeeded()
                if forceLifecycleRefresh {
                    webView.browserPortalForceRenderingStateRefresh(reason: reason)
                } else {
                    webView.browserPortalReattachRenderingState(reason: reason)
                }
                webView.displayIfNeeded()
            }
            if let hostedWebView {
                hostedWebView.browserPortalApplyFirstSizedRevealGeometryNudgeIfNeeded(
                    reason: reason,
                    companionSearchRoot: self,
                    relativeTo: window
                )
            }

            localInlineSlotView.displayIfNeeded()
            // Flush only this panel's subtree. A whole-window displayIfNeeded
            // here would also draw sibling Metal terminal panes — and this
            // method runs from updateNSView/viewDidMoveToWindow, inside the
            // layout pass, where a synchronous terminal draw can wedge the
            // main thread against the still-open window transaction. WebKit
            // subtree flushes carry no such wait.
            displayIfNeeded()
        }

        func prepareForWindowPortalHosting() {
            hostedInspectorDockConfigurationSyncScheduler.cancel()
            notifyHostedWebKitHidden(reason: "prepareForWindowPortalHosting")
            deactivateHostedInspectorSideDockIfNeeded(reparentTo: localInlineSlotView)
            hostedInspectorFrontendWebView = nil
            lastHostedInspectorManualSideDockAllowed = nil
            lastHostedInspectorDetachedFromHostWindow = nil
        }

        func clearStaleHostedInspectorOwnershipState() {
            hostedInspectorDockConfigurationSyncScheduler.cancel()
            hostedInspectorFrontendWebView = nil
            lastHostedInspectorManualSideDockAllowed = nil
            lastHostedInspectorDetachedFromHostWindow = nil
        }

        func releaseHostedWebViewConstraints() {
            NSLayoutConstraint.deactivate(hostedWebViewConstraints)
            hostedWebViewConstraints = []
            hostedWebView = nil
        }

        func pinHostedWebView(_ webView: WKWebView, in container: NSView) {
            let presentationView = webView.cmuxBrowserViewportPresentationView
            guard presentationView.superview === container ||
                    presentationView.isDescendant(of: container) else { return }

            let hasCompanionWKSubviews = container.browserPortalHasVisibleWebKitCompanionSubview(for: webView)
            let needsPlainWebViewFrameReset =
                presentationView.superview === container &&
                !hasCompanionWKSubviews &&
                !webView.cmuxBrowserViewportLayoutMatches(container.bounds)
            let needsFrameHosting =
                hostedWebView !== webView ||
                !hostedWebViewConstraints.isEmpty ||
                needsPlainWebViewFrameReset ||
                !presentationView.translatesAutoresizingMaskIntoConstraints
            guard needsFrameHosting else {
                needsLayout = true
                layoutSubtreeIfNeeded()
                return
            }

            NSLayoutConstraint.deactivate(hostedWebViewConstraints)
            hostedWebViewConstraints = []
            hostedWebView = webView

            // WebKit's attached inspector does not reliably dock into a constraint-managed
            // WKWebView hierarchy on macOS. Host the moved webview with autoresizing and
            // preserve WebKit-managed split frames when docked DevTools siblings exist.
            if presentationView.superview === container && !hasCompanionWKSubviews {
                webView.cmuxApplyBrowserViewportLayout(in: container.bounds)
            } else {
                presentationView.translatesAutoresizingMaskIntoConstraints = true
                presentationView.autoresizingMask = [.width, .height]
            }
            needsLayout = true
            layoutSubtreeIfNeeded()
        }

        private func ensureHostedInspectorSideDockContainerView() -> HostedInspectorSideDockContainerView {
            if let hostedInspectorSideDockContainerView,
               hostedInspectorSideDockContainerView.superview === self {
                hostedInspectorSideDockContainerView.isHidden = false
                return hostedInspectorSideDockContainerView
            }

            let containerView = HostedInspectorSideDockContainerView(frame: bounds)
            containerView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(containerView, positioned: .above, relativeTo: localInlineSlotView)
            hostedInspectorSideDockConstraints = [
                containerView.topAnchor.constraint(equalTo: topAnchor),
                containerView.bottomAnchor.constraint(equalTo: bottomAnchor),
                containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
                containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ]
            NSLayoutConstraint.activate(hostedInspectorSideDockConstraints)
            hostedInspectorSideDockContainerView = containerView
            return containerView
        }

        private func moveHostedInspectorSubviewIfNeeded(_ view: NSView, to container: NSView) {
            guard view.superview !== container else { return }
            let frameInWindow = view.superview?.convert(view.frame, to: nil) ?? convert(view.frame, to: nil)
            view.removeFromSuperview()
            container.addSubview(view, positioned: .above, relativeTo: nil)
            view.frame = container.convert(frameInWindow, from: nil)
        }

        private func isHostedInspectorSideDockActive() -> Bool {
            guard let hostedInspectorSideDockContainerView,
                  let hostedInspectorSideDockPageView,
                  let hostedInspectorSideDockInspectorView else {
                return false
            }
            return hostedInspectorSideDockPageView.superview === hostedInspectorSideDockContainerView &&
                hostedInspectorSideDockInspectorView.superview === hostedInspectorSideDockContainerView
        }

        private func isHostedInspectorSideDockHit(_ hit: HostedInspectorDividerHit) -> Bool {
            guard let hostedInspectorSideDockContainerView else { return false }
            return hit.containerView === hostedInspectorSideDockContainerView
        }

        private func activateHostedInspectorSideDockIfNeeded(using hit: HostedInspectorDividerHit) {
            let containerView = ensureHostedInspectorSideDockContainerView()
            moveHostedInspectorSubviewIfNeeded(hit.pageView, to: containerView)
            moveHostedInspectorSubviewIfNeeded(hit.inspectorView, to: containerView)
            hostedInspectorSideDockPageView = hit.pageView
            hostedInspectorSideDockInspectorView = hit.inspectorView
            hostedInspectorSideDockDockSide = hit.dockSide
            layoutHostedInspectorSideDockIfNeeded(reason: "sideDock.activate")
        }

        @discardableResult
        func promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded() -> Bool {
            guard !isHostedInspectorSideDockActive(),
                  let slotView = localInlineSlotView,
                  let hit = hostedInspectorDividerCandidateUsingKnownWebViews(in: slotView) else {
                return false
            }

            // The inspector frontend sometimes reports its dock configuration a tick
            // late after local-inline reattach. Promote the visible left/right split
            // immediately so drag routing stays symmetric on both dock sides. Adaptive
            // bottom-dock enforcement runs from layout after the managed container owns
            // the split, so synchronous promotion cannot lose the divider path.
            activateHostedInspectorSideDockIfNeeded(using: hit)
            return isHostedInspectorSideDockActive()
        }

        /// Schedules `promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded`
        /// for the next runloop tick when a promotion is actually pending, so the
        /// hierarchy mutation it performs never runs inside the `layout()` pass
        /// that observed the candidate (see the note in `layout()`). The candidate
        /// lookup here is read-only; the deferred work re-validates all state
        /// before mutating, so it is safe even if the layout changes in between.
        private func scheduleHostedInspectorSideDockPromotionIfNeeded() {
            guard hostedInspectorSideDockPromotionTask == nil else { return }
            guard !isHostedInspectorSideDockActive(),
                  let slotView = localInlineSlotView,
                  hostedInspectorDividerCandidateUsingKnownWebViews(in: slotView) != nil else {
                return
            }
            let taskID = UUID()
            hostedInspectorSideDockPromotionTaskID = taskID
            let task = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                guard self.hostedInspectorSideDockPromotionTaskID == taskID else { return }
                self.hostedInspectorSideDockPromotionTask = nil
                self.hostedInspectorSideDockPromotionTaskID = nil
                guard !Task.isCancelled else { return }
                _ = self.promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded()
            }
            hostedInspectorSideDockPromotionTask = task
        }

        private func deactivateHostedInspectorSideDockIfNeeded(reparentTo slotView: WindowBrowserSlotView?) {
            guard let slotView,
                  let pageView = hostedInspectorSideDockPageView,
                  let inspectorView = hostedInspectorSideDockInspectorView else {
                hostedInspectorSideDockPageView = nil
                hostedInspectorSideDockInspectorView = nil
                hostedInspectorSideDockDockSide = nil
                hostedInspectorSideDockContainerView?.isHidden = true
                return
            }

            moveHostedInspectorSubviewIfNeeded(pageView, to: slotView)
            moveHostedInspectorSubviewIfNeeded(inspectorView, to: slotView)
            hostedInspectorSideDockPageView = nil
            hostedInspectorSideDockInspectorView = nil
            hostedInspectorSideDockDockSide = nil
            hostedInspectorSideDockContainerView?.isHidden = true
        }

        private func layoutHostedInspectorSideDockIfNeeded(reason: String) {
            guard let containerView = hostedInspectorSideDockContainerView,
                  let pageView = hostedInspectorSideDockPageView,
                  let inspectorView = hostedInspectorSideDockInspectorView,
                  let dockSide = hostedInspectorSideDockDockSide else {
                return
            }
            let preferredWidth = resolvedPreferredHostedInspectorWidth(in: containerView.bounds) ?? max(0, inspectorView.frame.width)
            _ = applyHostedInspectorDividerWidth(
                preferredWidth,
                to: HostedInspectorDividerHit(
                    containerView: containerView,
                    pageView: pageView,
                    inspectorView: inspectorView,
                    dockSide: dockSide
                ),
                minimumInspectorWidth: Self.minimumHostedInspectorWidth,
                reason: reason
            )
        }

        func normalizeHostedInspectorLayoutIfNeeded(reason: String) {
            if enforceAdaptiveBottomDockIfNeeded(reason: "\(reason).adaptive") {
                return
            }
            _ = promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded()
            if isHostedInspectorSideDockActive() {
                layoutHostedInspectorSideDockIfNeeded(reason: reason)
            } else if !hasStoredHostedInspectorWidthPreference {
                captureHostedInspectorPreferredWidthFromCurrentLayout(reason: reason)
            }
        }

        private func shouldForceHostedInspectorBottomDock(using hit: HostedInspectorDividerHit) -> Bool {
            let containerWidth = max(0, hit.containerView.bounds.width)
            guard containerWidth > 1 else { return false }

            let currentInspectorWidth = max(0, hit.inspectorView.frame.width)
            let currentPageWidth = max(0, hit.pageView.frame.width)
            let remainingPageWidth = max(0, containerWidth - max(Self.minimumHostedInspectorWidth, currentInspectorWidth))
            let effectivePageWidth = min(currentPageWidth, remainingPageWidth)

            return effectivePageWidth < Self.minimumHostedInspectorPageWidthForSideDock
        }

        @discardableResult
        private func requestAdaptiveHostedInspectorBottomDock(reason: String) -> Bool {
            let now = Date()
            if let adaptiveBottomDockRequestCooldownDeadline, adaptiveBottomDockRequestCooldownDeadline > now {
                return true
            }
            guard let hostedInspectorFrontendWebView else { return false }

            adaptiveBottomDockRequestCooldownDeadline = now.addingTimeInterval(Self.adaptiveBottomDockRequestCooldown)
            updateHostedInspectorDockControlAvailabilityIfNeeded(reason: reason)
#if DEBUG
            cmuxDebugLog(
                "browser.panel.hostedInspector stage=\(reason).adaptiveBottomDock " +
                "host=\(Self.debugObjectID(self)) bounds=\(Self.debugRect(bounds))"
            )
#endif
            hostedInspectorFrontendWebView.evaluateJavaScript(
                "typeof WI !== 'undefined' ? WI._dockBottom() : null"
            ) { [weak self] _, _ in
                self?.scheduleHostedInspectorDockConfigurationSync(
                    reason: "\(reason).adaptiveBottomDock"
                )
            }
            return true
        }

        @discardableResult
        private func enforceAdaptiveBottomDockIfNeeded(reason: String) -> Bool {
            guard let hit = hostedInspectorDividerCandidate(),
                  shouldForceHostedInspectorBottomDock(using: hit) else {
                return false
            }
            recordHostedInspectorSideDockWidth(hit.inspectorView.frame.width)
            return requestAdaptiveHostedInspectorBottomDock(reason: reason)
        }

        fileprivate func scheduleHostedInspectorDockConfigurationSync(reason: String) {
            hostedInspectorDockConfigurationSyncScheduler.cancel()
            guard hostedInspectorFrontendWebView != nil else { return }
            hostedInspectorDockConfigurationSyncScheduler.schedule { [weak self] in
                self?.syncHostedInspectorDockConfiguration(reason: reason)
            }
        }

        private func syncHostedInspectorDockConfiguration(reason: String) {
            guard let hostedInspectorFrontendWebView else { return }
            hostedInspectorFrontendWebView.evaluateJavaScript(
                "typeof WI === 'undefined' ? null : WI.dockConfiguration"
            ) { [weak self] result, _ in
                self?.applyHostedInspectorDockConfiguration(result as? String, reason: reason)
            }
        }

        private func applyHostedInspectorDockConfiguration(_ dockConfiguration: String?, reason: String) {
            switch dockConfiguration {
            case "left":
                hostedInspectorSideDockDockSide = .leading
                if isHostedInspectorSideDockActive() {
                    if enforceAdaptiveBottomDockIfNeeded(reason: "\(reason).dockLeft") {
                        return
                    }
                    layoutHostedInspectorSideDockIfNeeded(reason: "\(reason).dockLeft")
                } else if let slotView = localInlineSlotView,
                          let hit = hostedInspectorDividerCandidate(in: slotView),
                          hit.dockSide == .leading {
                    if shouldForceHostedInspectorBottomDock(using: hit) {
                        _ = requestAdaptiveHostedInspectorBottomDock(reason: "\(reason).dockLeft")
                        return
                    }
                    activateHostedInspectorSideDockIfNeeded(using: hit)
                }
            case "right":
                hostedInspectorSideDockDockSide = .trailing
                if isHostedInspectorSideDockActive() {
                    if enforceAdaptiveBottomDockIfNeeded(reason: "\(reason).dockRight") {
                        return
                    }
                    layoutHostedInspectorSideDockIfNeeded(reason: "\(reason).dockRight")
                } else if let slotView = localInlineSlotView,
                          let hit = hostedInspectorDividerCandidate(in: slotView),
                          hit.dockSide == .trailing {
                    if shouldForceHostedInspectorBottomDock(using: hit) {
                        _ = requestAdaptiveHostedInspectorBottomDock(reason: "\(reason).dockRight")
                        return
                    }
                    activateHostedInspectorSideDockIfNeeded(using: hit)
                }
            default:
                adaptiveBottomDockRequestCooldownDeadline = nil
                if isHostedInspectorSideDockActive() {
                    deactivateHostedInspectorSideDockIfNeeded(reparentTo: localInlineSlotView)
                    if dockConfiguration == "bottom" {
                        hostedInspectorFrontendWebView?.evaluateJavaScript(
                            "typeof WI !== 'undefined' ? WI._dockBottom() : null",
                            completionHandler: nil
                        )
                    }
                }
            }
            updateHostedInspectorDockControlAvailabilityIfNeeded(reason: "\(reason).dockConfiguration")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                notifyHostedWebKitHidden(reason: "viewDidMoveToWindow")
                clearActiveDividerCursor(restoreArrow: false)
            } else {
                scheduleHostedInspectorDividerReapply(reason: "viewDidMoveToWindow")
                scheduleHostedInspectorDockConfigurationSync(reason: "viewDidMoveToWindow")
                refreshHostedWebKitPresentation(
                    reason: "viewDidMoveToWindow",
                    forceLifecycleRefresh: hostedInspectorFrontendWebView != nil
                )
            }
            window?.invalidateCursorRects(for: self)
            onDidMoveToWindow?()
            notifyGeometryChangedIfNeeded()
#if DEBUG
            debugLogHostedInspectorLayoutIfNeeded(reason: "viewDidMoveToWindow")
#endif
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            scheduleHostedInspectorDividerReapply(reason: "viewDidMoveToSuperview")
            scheduleHostedInspectorDockConfigurationSync(reason: "viewDidMoveToSuperview")
            notifyGeometryChangedIfNeeded()
#if DEBUG
            debugLogHostedInspectorLayoutIfNeeded(reason: "viewDidMoveToSuperview")
#endif
        }

        override func layout() {
            super.layout()
            if enforceAdaptiveBottomDockIfNeeded(reason: "host.layout") {
                updateHostedInspectorDockControlAvailabilityIfNeeded(reason: "host.layout")
                notifyGeometryChangedIfNeeded()
#if DEBUG
                debugLogHostedInspectorLayoutIfNeeded(reason: "layout")
#endif
                return
            }
            // Defer this hierarchy mutation out of `layout()` to avoid #6150.
            scheduleHostedInspectorSideDockPromotionIfNeeded()
            if let previousSize = lastHostedInspectorLayoutBoundsSize,
               Self.sizeApproximatelyEqual(previousSize, bounds.size, epsilon: 0.5) {
                // Origin-only frame churn is common while the surrounding split layout
                // settles. Reapplying the side-docked inspector at the same size fights
                // WebKit's own dock layout and shows up as visible flicker.
                if !isHostedInspectorDividerDragActive {
                    if hasStoredHostedInspectorWidthPreference {
                        reapplyHostedInspectorDividerToStoredWidthIfNeeded(reason: "host.layout.sameSize")
                    } else if !isHostedInspectorSideDockActive() {
                        captureHostedInspectorPreferredWidthFromCurrentLayout(reason: "host.layout.sameSize")
                    }
                }
                updateHostedInspectorDockControlAvailabilityIfNeeded(reason: "host.layout.sameSize")
                notifyGeometryChangedIfNeeded()
#if DEBUG
                debugLogHostedInspectorLayoutIfNeeded(reason: "layout")
#endif
                return
            }
            lastHostedInspectorLayoutBoundsSize = bounds.size
            if isHostedInspectorSideDockActive() {
                layoutHostedInspectorSideDockIfNeeded(reason: "host.layout.sideDock")
            } else if hasStoredHostedInspectorWidthPreference {
                reapplyHostedInspectorDividerToStoredWidthIfNeeded(reason: "host.layout")
            } else {
                captureHostedInspectorPreferredWidthFromCurrentLayout(reason: "host.layout")
            }
            updateHostedInspectorDockControlAvailabilityIfNeeded(reason: "host.layout")
            scheduleHostedInspectorDockConfigurationSync(reason: "layout")
            notifyGeometryChangedIfNeeded()
#if DEBUG
            debugLogHostedInspectorLayoutIfNeeded(reason: "layout")
#endif
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            window?.invalidateCursorRects(for: self)
            // Mark dirty; the callback fires from layout() with the settled geometry.
            markGeometryDirtyIfNeeded()
#if DEBUG
            debugLogHostedInspectorLayoutIfNeeded(reason: "setFrameOrigin")
#endif
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            window?.invalidateCursorRects(for: self)
            // Mark dirty; the callback fires from layout() with the settled geometry.
            markGeometryDirtyIfNeeded()
#if DEBUG
            debugLogHostedInspectorLayoutIfNeeded(reason: "setFrameSize")
#endif
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            guard let hostedInspectorHit = hostedInspectorDividerCandidate() else { return }
            let clipped = hostedInspectorDividerHitRect(for: hostedInspectorHit).intersection(bounds)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return }
            addCursorRect(clipped, cursor: NSCursor.resizeLeftRight)
        }

        override func updateTrackingAreas() {
            if let trackingArea {
                removeTrackingArea(trackingArea)
            }
            let options: NSTrackingArea.Options = [
                .inVisibleRect,
                .activeAlways,
                .cursorUpdate,
                .mouseMoved,
                .mouseEnteredAndExited,
                .enabledDuringMouseDrag,
            ]
            let next = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
            addTrackingArea(next)
            trackingArea = next
            super.updateTrackingAreas()
        }

        override func cursorUpdate(with event: NSEvent) {
            updateDividerCursor(at: convert(event.locationInWindow, from: nil))
        }

        override func mouseMoved(with event: NSEvent) {
            updateDividerCursor(at: convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) {
            clearActiveDividerCursor(restoreArrow: true)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let hostedInspectorHit = hostedInspectorDividerHit(at: point)
            updateDividerCursor(at: point, hostedInspectorHit: hostedInspectorHit)
            let passThrough = shouldPassThroughToSidebarResizer(at: point, hostedInspectorHit: hostedInspectorHit)
            if passThrough {
#if DEBUG
                debugLogHitTest(stage: "hitTest.pass", point: point, passThrough: true, hitView: nil)
#endif
                return nil
            }
            if shouldPassThroughToExternalSplitDivider(at: point, hostedInspectorHit: hostedInspectorHit) {
#if DEBUG
                debugLogHitTest(stage: "hitTest.splitPass", point: point, passThrough: true, hitView: nil)
#endif
                return nil
            }
            if let hostedInspectorHit {
                if let nativeHit = nativeHostedInspectorHit(at: point, hostedInspectorHit: hostedInspectorHit) {
#if DEBUG
                    debugLogHitTest(stage: "hitTest.hostedInspectorNative", point: point, passThrough: false, hitView: nativeHit)
#endif
                    if nativeHit !== hostedInspectorHit.inspectorView &&
                        !hostedInspectorHit.inspectorView.isDescendant(of: nativeHit) {
                        return nativeHit
                    }
                }
#if DEBUG
                debugLogHitTest(
                    stage: "hitTest.hostedInspectorManual",
                    point: point,
                    passThrough: false,
                    hitView: self
                )
#endif
                return self
            }
            let hit = super.hitTest(point)
#if DEBUG
            debugLogHitTest(stage: "hitTest.result", point: point, passThrough: false, hitView: hit)
#endif
            return hit
        }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            guard let hostedInspectorHit = hostedInspectorDividerHit(at: point) else {
                super.mouseDown(with: event)
                return
            }

            hostedInspectorReapplyScheduler.cancel()
            isHostedInspectorDividerDragActive = true
            hostedInspectorDividerDrag = HostedInspectorDividerDragState(
                containerView: hostedInspectorHit.containerView,
                pageView: hostedInspectorHit.pageView,
                inspectorView: hostedInspectorHit.inspectorView,
                dockSide: hostedInspectorHit.dockSide,
                initialWindowX: event.locationInWindow.x,
                initialPageFrame: hostedInspectorHit.pageView.frame,
                initialInspectorFrame: hostedInspectorHit.inspectorView.frame
            )
#if DEBUG
            debugLogHostedInspectorFrames(stage: "drag.start", point: point, hit: hostedInspectorHit)
#endif
        }

        override func mouseDragged(with event: NSEvent) {
            guard let dragState = hostedInspectorDividerDrag else {
                super.mouseDragged(with: event)
                return
            }

            let containerBounds = dragState.containerView.bounds
            let minimumInspectorWidth = Self.minimumHostedInspectorWidth
            let initialDividerX = dragState.dockSide.dividerX(
                pageFrame: dragState.initialPageFrame,
                inspectorFrame: dragState.initialInspectorFrame
            )
            let proposedDividerX = initialDividerX + (event.locationInWindow.x - dragState.initialWindowX)
            let clampedDividerX = dragState.dockSide.clampedDividerX(
                proposedDividerX,
                containerBounds: containerBounds,
                pageFrame: dragState.initialPageFrame,
                minimumInspectorWidth: minimumInspectorWidth
            )
            let inspectorWidth = dragState.dockSide.inspectorWidth(
                forDividerX: clampedDividerX,
                in: containerBounds
            )
            recordPreferredHostedInspectorWidth(inspectorWidth, containerBounds: containerBounds)
            _ = applyHostedInspectorDividerWidth(
                inspectorWidth,
                to: HostedInspectorDividerHit(
                    containerView: dragState.containerView,
                    pageView: dragState.pageView,
                    inspectorView: dragState.inspectorView,
                    dockSide: dragState.dockSide
                ),
                minimumInspectorWidth: Self.minimumHostedInspectorWidth,
                reason: "drag"
            )
#if DEBUG
            debugLogHostedInspectorFrames(
                stage: "drag.update",
                point: convert(event.locationInWindow, from: nil),
                hit: HostedInspectorDividerHit(
                    containerView: dragState.containerView,
                    pageView: dragState.pageView,
                    inspectorView: dragState.inspectorView,
                    dockSide: dragState.dockSide
                )
            )
#endif
            updateDividerCursor(
                at: convert(event.locationInWindow, from: nil),
                hostedInspectorHit: HostedInspectorDividerHit(
                    containerView: dragState.containerView,
                    pageView: dragState.pageView,
                    inspectorView: dragState.inspectorView,
                    dockSide: dragState.dockSide
                )
            )
        }

        override func mouseUp(with event: NSEvent) {
            let finalDragState = hostedInspectorDividerDrag
            hostedInspectorDividerDrag = nil
            isHostedInspectorDividerDragActive = false
            updateDividerCursor(at: convert(event.locationInWindow, from: nil))
            if let finalDragState {
#if DEBUG
                debugLogHostedInspectorFrames(
                    stage: "drag.end",
                    point: convert(event.locationInWindow, from: nil),
                    hit: HostedInspectorDividerHit(
                        containerView: finalDragState.containerView,
                        pageView: finalDragState.pageView,
                        inspectorView: finalDragState.inspectorView,
                        dockSide: finalDragState.dockSide
                    )
                )
#endif
                reapplyHostedInspectorDividerToStoredWidthIfNeeded(reason: "drag.end")
            }
            super.mouseUp(with: event)
        }

        private func shouldPassThroughToSidebarResizer(
            at point: NSPoint,
            hostedInspectorHit: HostedInspectorDividerHit? = nil
        ) -> Bool {
            if hostedInspectorHit != nil {
                return false
            }
            // Pass through narrow content-edge bands so shared sidebar divider
            // handles receive hover/click even when WKWebView is attached here.
            let isLeadingContentEdge = point.x >= 0 &&
                point.x <= SidebarResizeInteraction.contentSideHitWidth
            let isTrailingContentEdge = point.x >= bounds.maxX - SidebarResizeInteraction.contentSideHitWidth &&
                point.x <= bounds.maxX
            guard isLeadingContentEdge || isTrailingContentEdge else {
                return false
            }
            guard let window, let contentView = window.contentView else {
                return false
            }
            let hostRectInContent = contentView.convert(bounds, from: self)
            if isLeadingContentEdge {
                return hostRectInContent.minX > 1
            }
            return contentView.bounds.maxX - hostRectInContent.maxX > 24
        }

        private func shouldPassThroughToExternalSplitDivider(
            at point: NSPoint,
            hostedInspectorHit: HostedInspectorDividerHit? = nil
        ) -> Bool {
            guard hostedInspectorHit == nil else { return false }
            guard isNearPaneEdge(point) else { return false }
            guard window != nil else { return false }

            let windowPoint = convert(point, to: nil)
            var ancestor = superview
            while let currentAncestor = ancestor {
                if let splitView = currentAncestor as? NSSplitView,
                   let arrangedIndex = splitView.arrangedSubviews.firstIndex(where: { arrangedSubview in
                       self === arrangedSubview || self.isDescendant(of: arrangedSubview)
                   }) {
                    if externalSplitDividerHit(at: windowPoint, in: splitView, dividerIndex: arrangedIndex - 1) {
                        return true
                    }
                    if externalSplitDividerHit(at: windowPoint, in: splitView, dividerIndex: arrangedIndex) {
                        return true
                    }
                }
                ancestor = currentAncestor.superview
            }
            return false
        }

        private func externalSplitDividerHit(
            at windowPoint: NSPoint,
            in splitView: NSSplitView,
            dividerIndex: Int
        ) -> Bool {
            guard let window,
                  splitView.window === window,
                  let hitRect = PortalSplitDividerRegion.dividerHitRectInWindow(
                      in: splitView,
                      dividerIndex: dividerIndex
                  ) else {
                return false
            }
            return hitRect.contains(windowPoint)
        }

        private func isNearPaneEdge(_ point: NSPoint) -> Bool {
            // hitTest and cursor tracking call this with points in this view's bounds coordinates.
            guard bounds.contains(point) else { return false }
            let expansion = PortalSplitDividerRegion.dividerHitExpansion
            let nearVerticalEdge = point.x <= bounds.minX + expansion ||
                point.x >= bounds.maxX - expansion
            let nearHorizontalEdge = point.y <= bounds.minY + expansion ||
                point.y >= bounds.maxY - expansion
            return nearVerticalEdge || nearHorizontalEdge
        }

        private func updateDividerCursor(
            at point: NSPoint,
            hostedInspectorHit: HostedInspectorDividerHit? = nil
        ) {
            let resolvedHostedInspectorHit = hostedInspectorHit ?? hostedInspectorDividerHit(at: point)
            if shouldPassThroughToSidebarResizer(at: point, hostedInspectorHit: resolvedHostedInspectorHit) {
                clearActiveDividerCursor(restoreArrow: false)
                return
            }
            if shouldPassThroughToExternalSplitDivider(at: point, hostedInspectorHit: resolvedHostedInspectorHit) {
                clearActiveDividerCursor(restoreArrow: false)
                return
            }
            guard resolvedHostedInspectorHit != nil else {
                clearActiveDividerCursor(restoreArrow: true)
                return
            }
            guard dividerCursorOcclusion.mayAssertDividerCursor(in: window) else {
                clearActiveDividerCursor(restoreArrow: false)
                return
            }
            activeDividerCursorKind = .vertical
            NSCursor.resizeLeftRight.set()
        }

        private func clearActiveDividerCursor(restoreArrow: Bool) {
            guard activeDividerCursorKind != nil else { return }
            window?.invalidateCursorRects(for: self)
            activeDividerCursorKind = nil
            if restoreArrow {
                NSCursor.arrow.set()
            }
        }

        private func nativeHostedInspectorHit(
            at point: NSPoint,
            hostedInspectorHit: HostedInspectorDividerHit
        ) -> NSView? {
            guard let nativeHit = super.hitTest(point), nativeHit !== self else { return nil }
            if nativeHit === hostedInspectorHit.pageView ||
                nativeHit.isDescendant(of: hostedInspectorHit.pageView) {
                return nil
            }
            if nativeHit === hostedInspectorHit.inspectorView ||
                nativeHit.isDescendant(of: hostedInspectorHit.inspectorView) {
                return nativeHit
            }
            if hostedInspectorHit.inspectorView.isDescendant(of: nativeHit),
               !(hostedInspectorHit.pageView === nativeHit || hostedInspectorHit.pageView.isDescendant(of: nativeHit)) {
                return nativeHit
            }
            return nil
        }

        private func hostedInspectorDividerHit(at point: NSPoint) -> HostedInspectorDividerHit? {
            guard let hit = hostedInspectorDividerCandidate(),
                  hostedInspectorDividerHitRect(for: hit).contains(point) else {
                return nil
            }
            return hit
        }

        private func hostedInspectorDividerCandidate() -> HostedInspectorDividerHit? {
            hostedInspectorDividerCandidate(in: self)
        }

        private func hostedInspectorDividerCandidate(in root: NSView) -> HostedInspectorDividerHit? {
            if let preferredHit = hostedInspectorDividerCandidateUsingKnownWebViews(in: root) {
                return preferredHit
            }

            let inspectorCandidates = Self.visibleDescendants(in: root)
                .filter { Self.isVisibleHostedInspectorCandidate($0) && Self.isInspectorView($0) }
                .sorted { lhs, rhs in
                    let lhsFrame = root.convert(lhs.bounds, from: lhs)
                    let rhsFrame = root.convert(rhs.bounds, from: rhs)
                    return lhsFrame.minX < rhsFrame.minX
                }

            var bestHit: HostedInspectorDividerHit?
            var bestScore = -CGFloat.greatestFiniteMagnitude

            for inspectorCandidate in inspectorCandidates {
                guard let candidate = hostedInspectorDividerCandidate(in: root, startingAt: inspectorCandidate) else {
                    continue
                }
                let score = hostedInspectorDividerCandidateScore(candidate)
                if score > bestScore {
                    bestScore = score
                    bestHit = candidate
                }
            }

            return bestHit
        }

        private func hostedInspectorDividerCandidateUsingKnownWebViews(in root: NSView) -> HostedInspectorDividerHit? {
            guard let pageLeaf = hostedWebView,
                  let inspectorLeaf = hostedInspectorFrontendWebView,
                  pageLeaf.isDescendant(of: root),
                  inspectorLeaf.isDescendant(of: root),
                  Self.isVisibleHostedInspectorCandidate(inspectorLeaf) else {
                return nil
            }
            return hostedInspectorDividerCandidate(
                in: root,
                pageLeaf: pageLeaf,
                inspectorLeaf: inspectorLeaf
            )
        }

        private func hostedInspectorDividerCandidate(
            in root: NSView,
            pageLeaf: NSView,
            inspectorLeaf: NSView
        ) -> HostedInspectorDividerHit? {
            var currentInspector: NSView? = inspectorLeaf

            while let inspectorView = currentInspector, inspectorView !== root {
                guard let containerView = inspectorView.superview else { break }
                guard containerView === root || containerView.isDescendant(of: root) else {
                    currentInspector = containerView
                    continue
                }
                guard let pageView = Self.directChild(of: containerView, containing: pageLeaf) else {
                    currentInspector = containerView
                    continue
                }
                guard pageView !== inspectorView,
                      Self.isVisibleHostedInspectorSiblingCandidate(pageView),
                      Self.verticalOverlap(between: pageView.frame, and: inspectorView.frame) > 8,
                      let dockSide = HostedInspectorDockSide.resolve(
                          pageFrame: pageView.frame,
                          inspectorFrame: inspectorView.frame
                      ) else {
                    currentInspector = containerView
                    continue
                }
                return HostedInspectorDividerHit(
                    containerView: containerView,
                    pageView: pageView,
                    inspectorView: inspectorView,
                    dockSide: dockSide
                )
            }

            return nil
        }

        private func hostedInspectorDividerHitRect(for hit: HostedInspectorDividerHit) -> NSRect {
            let pageFrame = convert(hit.pageView.bounds, from: hit.pageView)
            let inspectorFrame = convert(hit.inspectorView.bounds, from: hit.inspectorView)
            return hit.dockSide.dividerHitRect(
                in: bounds,
                pageFrame: pageFrame,
                inspectorFrame: inspectorFrame,
                expansion: Self.hostedInspectorDividerHitExpansion
            )
        }

        private func hostedInspectorDividerCandidate(in root: NSView, startingAt inspectorLeaf: NSView) -> HostedInspectorDividerHit? {
            var current: NSView? = inspectorLeaf
            var bestHit: HostedInspectorDividerHit?

            while let inspectorView = current, inspectorView !== root {
                guard let containerView = inspectorView.superview else { break }

                let pageCandidates = containerView.subviews.compactMap { candidate -> (view: NSView, dockSide: HostedInspectorDockSide)? in
                    guard Self.isVisibleHostedInspectorSiblingCandidate(candidate) else { return nil }
                    guard candidate !== inspectorView else { return nil }
                    guard Self.verticalOverlap(between: candidate.frame, and: inspectorView.frame) > 8 else {
                        return nil
                    }
                    guard let dockSide = HostedInspectorDockSide.resolve(
                        pageFrame: candidate.frame,
                        inspectorFrame: inspectorView.frame
                    ) else {
                        return nil
                    }
                    return (view: candidate, dockSide: dockSide)
                }

                if let pageCandidate = pageCandidates.max(by: {
                    hostedInspectorPageCandidateScore($0.view, inspectorView: inspectorView)
                        < hostedInspectorPageCandidateScore($1.view, inspectorView: inspectorView)
                }) {
                    bestHit = HostedInspectorDividerHit(
                        containerView: containerView,
                        pageView: pageCandidate.view,
                        inspectorView: inspectorView,
                        dockSide: pageCandidate.dockSide
                    )
                }

                current = containerView
            }

            return bestHit
        }

        private func hostedInspectorDividerCandidateScore(_ hit: HostedInspectorDividerHit) -> CGFloat {
            let pageFrame = convert(hit.pageView.bounds, from: hit.pageView)
            let inspectorFrame = convert(hit.inspectorView.bounds, from: hit.inspectorView)
            let overlap = Self.verticalOverlap(between: pageFrame, and: inspectorFrame)
            let coverageWidth = max(pageFrame.maxX, inspectorFrame.maxX) - min(pageFrame.minX, inspectorFrame.minX)
            return (overlap * 1_000) + coverageWidth + pageFrame.width
        }

        private func hostedInspectorPageCandidateScore(_ pageView: NSView, inspectorView: NSView) -> CGFloat {
            let overlap = Self.verticalOverlap(between: pageView.frame, and: inspectorView.frame)
            let coverageWidth = max(pageView.frame.maxX, inspectorView.frame.maxX) - min(pageView.frame.minX, inspectorView.frame.minX)
            return (overlap * 1_000) + coverageWidth + pageView.frame.width
        }

        fileprivate func scheduleHostedInspectorDividerReapply(reason: String) {
            hostedInspectorReapplyScheduler.schedule { [weak self] in
                guard let self else { return }
                _ = self.promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded()
                if self.hasStoredHostedInspectorWidthPreference {
                    self.reapplyHostedInspectorDividerToStoredWidthIfNeeded(reason: reason)
                } else {
                    self.captureHostedInspectorPreferredWidthFromCurrentLayout(reason: reason)
                }
            }
        }

        private func captureHostedInspectorPreferredWidthFromCurrentLayout(reason: String) {
            guard !isApplyingHostedInspectorLayout else { return }
            guard !isHostedInspectorDividerDragActive else { return }
            guard let hit = hostedInspectorDividerCandidate() else {
#if DEBUG
                if !hasLoggedMissingHostedInspectorCandidate {
                    hasLoggedMissingHostedInspectorCandidate = true
                    let preferredWidthDesc = preferredHostedInspectorWidth.map {
                        String(format: "%.1f", $0)
                    } ?? "nil"
                    cmuxDebugLog(
                        "browser.panel.hostedInspector stage=\(reason).captureMissingCandidate " +
                        "host=\(Self.debugObjectID(self)) preferredWidth=\(preferredWidthDesc)"
                    )
                }
#endif
                return
            }

            let inspectorWidth = max(0, hit.inspectorView.frame.width)
            guard inspectorWidth > 1 else { return }
            recordHostedInspectorSideDockWidth(inspectorWidth)
            let currentFraction: CGFloat? = {
                guard hit.containerView.bounds.width > 0 else { return nil }
                return inspectorWidth / hit.containerView.bounds.width
            }()
            let widthMatches = preferredHostedInspectorWidth.map {
                abs($0 - inspectorWidth) <= 0.5
            } ?? false
            let fractionMatches: Bool = {
                switch (preferredHostedInspectorWidthFraction, currentFraction) {
                case (nil, nil):
                    return true
                case let (lhs?, rhs?):
                    return abs(lhs - rhs) <= 0.001
                default:
                    return false
                }
            }()
            guard !(widthMatches && fractionMatches) else { return }

#if DEBUG
            hasLoggedMissingHostedInspectorCandidate = false
#endif
            recordPreferredHostedInspectorWidth(
                inspectorWidth,
                containerBounds: hit.containerView.bounds
            )
        }

        private func reapplyHostedInspectorDividerToStoredWidthIfNeeded(reason: String) {
            guard !isApplyingHostedInspectorLayout else { return }
            guard let hit = hostedInspectorDividerCandidate() else { return }
            guard let preferredWidth = resolvedPreferredHostedInspectorWidth(in: hit.containerView.bounds) else {
                return
            }
            let currentInspectorWidth = max(0, hit.inspectorView.frame.width)
            guard abs(currentInspectorWidth - preferredWidth) > 0.5 else { return }
            _ = applyHostedInspectorDividerWidth(
                preferredWidth,
                to: hit,
                minimumInspectorWidth: Self.minimumHostedInspectorWidth,
                reason: reason
            )
        }

        @discardableResult
        private func applyHostedInspectorDividerWidth(
            _ preferredWidth: CGFloat,
            to hit: HostedInspectorDividerHit,
            minimumInspectorWidth: CGFloat,
            reason: String
        ) -> (pageFrame: NSRect, inspectorFrame: NSRect) {
            let containerBounds = hit.containerView.bounds
            let nextFrames = hit.dockSide.resizedFrames(
                preferredWidth: preferredWidth,
                in: containerBounds,
                pageFrame: hit.pageView.frame,
                inspectorFrame: hit.inspectorView.frame,
                minimumInspectorWidth: minimumInspectorWidth
            )
            let pageFrame = nextFrames.pageFrame
            let inspectorFrame = nextFrames.inspectorFrame

            let oldPageFrame = hit.pageView.frame
            let oldInspectorFrame = hit.inspectorView.frame
            let pageChanged = !Self.rectApproximatelyEqual(pageFrame, oldPageFrame, epsilon: 0.5)
            let inspectorChanged = !Self.rectApproximatelyEqual(inspectorFrame, oldInspectorFrame, epsilon: 0.5)
            guard pageChanged || inspectorChanged else {
                return (pageFrame, inspectorFrame)
            }
            recordHostedInspectorSideDockWidth(inspectorFrame.width)

            isApplyingHostedInspectorLayout = true
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hit.pageView.frame = pageFrame
            hit.inspectorView.frame = inspectorFrame
            CATransaction.commit()
            isApplyingHostedInspectorLayout = false

            hit.pageView.needsDisplay = true
            hit.pageView.setNeedsDisplay(hit.pageView.bounds)
            hit.inspectorView.needsDisplay = true
            hit.inspectorView.setNeedsDisplay(hit.inspectorView.bounds)
            hit.containerView.needsDisplay = true
            hit.containerView.setNeedsDisplay(hit.containerView.bounds)
            if let localInlineSlotView {
                localInlineSlotView.needsDisplay = true
                localInlineSlotView.setNeedsDisplay(localInlineSlotView.bounds)
            }
            needsDisplay = true
            setNeedsDisplay(bounds)

            let isLiveDrag = reason == "drag"
#if DEBUG
            cmuxDebugLog(
                "browser.panel.hostedInspector stage=\(reason).reapply " +
                "host=\(Self.debugObjectID(self)) preferredWidth=\(String(format: "%.1f", preferredWidth)) " +
                "liveDrag=\(isLiveDrag ? 1 : 0) " +
                "pageChanged=\(pageChanged ? 1 : 0) inspectorChanged=\(inspectorChanged ? 1 : 0) " +
                "oldPage=\(Self.debugRect(oldPageFrame)) oldInspector=\(Self.debugRect(oldInspectorFrame)) " +
                "container=\(Self.debugObjectID(hit.containerView)) " +
                "pageFrame=\(Self.debugRect(pageFrame)) inspectorFrame=\(Self.debugRect(inspectorFrame))"
            )
#endif
            return (pageFrame, inspectorFrame)
        }

        private static func visibleDescendants(in root: NSView) -> [NSView] {
            var descendants: [NSView] = []
            var stack = Array(root.subviews.reversed())
            while let view = stack.popLast() {
                descendants.append(view)
                stack.append(contentsOf: view.subviews.reversed())
            }
            return descendants
        }

        private static func directChild(of container: NSView, containing descendant: NSView) -> NSView? {
            var current: NSView? = descendant
            var directChild: NSView?
            while let view = current, view !== container {
                directChild = view
                current = view.superview
            }
            guard current === container else { return nil }
            return directChild
        }

        fileprivate static func isInspectorView(_ view: NSView) -> Bool {
            cmuxIsWebInspectorObject(view)
        }

        fileprivate static func isVisibleHostedInspectorCandidate(_ view: NSView) -> Bool {
            !view.isHidden &&
                view.alphaValue > 0 &&
                view.frame.width > 1 &&
                view.frame.height > 1
        }

        private static func isVisibleHostedInspectorSiblingCandidate(_ view: NSView) -> Bool {
            !view.isHidden &&
                view.alphaValue > 0 &&
                view.frame.height > 1
        }

        private static func verticalOverlap(between lhs: NSRect, and rhs: NSRect) -> CGFloat {
            max(0, min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY))
        }
    }

    #if DEBUG
    private static func logDevToolsState(
        _ panel: BrowserPanel,
        event: String,
        generation: Int,
        retryCount: Int,
        details: String? = nil
    ) {
        var line = "browser.devtools event=\(event) panel=\(panel.id.uuidString.prefix(5)) generation=\(generation) retry=\(retryCount) \(panel.debugDeveloperToolsStateSummary())"
        if let details, !details.isEmpty {
            line += " \(details)"
        }
        cmuxDebugLog(line)
    }

    private static func objectID(_ object: AnyObject?) -> String {
        guard let object else { return "nil" }
        return String(describing: Unmanaged.passUnretained(object).toOpaque())
    }

    private static func responderDescription(_ responder: NSResponder?) -> String {
        guard let responder else { return "nil" }
        return "\(type(of: responder))@\(objectID(responder))"
    }

    private static func rectDescription(_ rect: NSRect) -> String {
        String(format: "%.1f,%.1f %.1fx%.1f", rect.origin.x, rect.origin.y, rect.size.width, rect.size.height)
    }

    private static func attachContext(webView: WKWebView, host: NSView) -> String {
        let hostWindow = host.window?.windowNumber ?? -1
        let webWindow = webView.window?.windowNumber ?? -1
        let firstResponder = (webView.window ?? host.window)?.firstResponder
        return "host=\(objectID(host)) hostWin=\(hostWindow) hostInWin=\(host.window == nil ? 0 : 1) hostFrame=\(rectDescription(host.frame)) hostBounds=\(rectDescription(host.bounds)) oldSuper=\(objectID(webView.superview)) webWin=\(webWindow) webInWin=\(webView.window == nil ? 0 : 1) webFrame=\(rectDescription(webView.frame)) webHidden=\(webView.isHidden ? 1 : 0) fr=\(responderDescription(firstResponder))"
    }
    #endif

    private static func responderChainContains(_ start: NSResponder?, target: NSResponder) -> Bool {
        var r = start
        var hops = 0
        while let cur = r, hops < 64 {
            if cur === target { return true }
            r = cur.nextResponder
            hops += 1
        }
        return false
    }

    private static func isLikelyInspectorResponder(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if cmuxIsWebInspectorObject(responder) {
            return true
        }
        guard let view = responder as? NSView else { return false }
        var node: NSView? = view
        var hops = 0
        while let current = node, hops < 64 {
            if cmuxIsWebInspectorObject(current) {
                return true
            }
            node = current.superview
            hops += 1
        }
        return false
    }

    private static func firstResponderResignState(
        _ responder: NSResponder?,
        webView: WKWebView
    ) -> (needsResign: Bool, flags: String) {
        let inWebViewChain = responderChainContains(responder, target: webView)
        let inspectorResponder = isLikelyInspectorResponder(responder)
        let needsResign = inWebViewChain || inspectorResponder
        return (
            needsResign: needsResign,
            flags: "frInWebChain=\(inWebViewChain ? 1 : 0) frIsInspector=\(inspectorResponder ? 1 : 0)"
        )
    }

    private static func clearPortalCallbacks(for host: NSView) {
        guard let host = host as? HostContainerView else { return }
        host.onDidMoveToWindow = nil
        host.onGeometryChanged = nil
        host.clearLocalInlineCallbacks()
    }

    private static func shouldPreserveExternalFullscreenHost(
        for webView: WKWebView,
        relativeTo expectedWindow: NSWindow?
    ) -> Bool {
        webView.cmuxIsManagedByExternalFullscreenWindow(relativeTo: expectedWindow)
    }

    private static func localInlineTransferRoot(for webView: WKWebView) -> NSView? {
        let presentationView = webView.cmuxBrowserViewportPresentationView
        var current = presentationView.superview
        var last: NSView?
        while let view = current {
            if view is WindowBrowserSlotView {
                return view
            }
            if view is HostContainerView {
                break
            }
            last = view
            current = view.superview
        }
        return last ?? presentationView.superview
    }

    private static func directTransferChild(of container: NSView, containing descendant: NSView) -> NSView? {
        var current: NSView? = descendant
        var directChild: NSView?
        while let view = current, view !== container {
            directChild = view
            current = view.superview
        }
        guard current === container else { return nil }
        return directChild
    }

    private static func relatedWebKitTransferSubviews(
        from sourceSuperview: NSView,
        primaryWebView: WKWebView
    ) -> [NSView] {
        var relatedSubviews: [NSView] = []
        var seen = Set<ObjectIdentifier>()
        func append(_ candidate: NSView?) {
            guard let candidate, candidate !== sourceSuperview else { return }
            let id = ObjectIdentifier(candidate)
            guard seen.insert(id).inserted else { return }
            relatedSubviews.append(candidate)
        }

        if let directChild = directTransferChild(of: sourceSuperview, containing: primaryWebView) {
            if let inspectorFrontendWebView = primaryWebView.cmuxInspectorFrontendWebView(),
               inspectorFrontendWebView === directChild || inspectorFrontendWebView.isDescendant(of: directChild) {
                append(primaryWebView)
            } else {
                append(directChild)
            }
        } else {
            append(primaryWebView)
        }
        let inspectorFrontendWebView = primaryWebView.cmuxInspectorFrontendWebView()
        for view in sourceSuperview.subviews {
            if view === primaryWebView { continue }
            if let inspectorFrontendWebView,
               inspectorFrontendWebView === view || inspectorFrontendWebView.isDescendant(of: view) {
                continue
            }
            let className = String(describing: type(of: view))
            if cmuxIsWebInspectorClassName(className) || cmuxIsWebInspectorObject(view) {
                continue
            }
            guard className.contains("WK") else { continue }
            append(view)
        }

        return relatedSubviews
    }

    private static func moveWebKitRelatedSubviewsIntoHostIfNeeded(
        from sourceSuperview: NSView,
        to container: WindowBrowserSlotView,
        primaryWebView: WKWebView,
        reason: String
    ) {
        let relatedSubviews = relatedWebKitTransferSubviews(
            from: sourceSuperview,
            primaryWebView: primaryWebView
        )
        guard !relatedSubviews.isEmpty else { return }
        let preserveSlotLocalFrames = sourceSuperview is WindowBrowserSlotView
        let sourceSlotBoundsSize = sourceSuperview.bounds.size
        var movedSubviewCount = 0
        var reusedSourceLocalFrames = false
#if DEBUG
        cmuxDebugLog(
            "browser.localHost.reparent.batch reason=\(reason) source=\(Self.objectID(sourceSuperview)) " +
            "container=\(Self.objectID(container)) count=\(relatedSubviews.count) " +
            "sourceType=\(String(describing: type(of: sourceSuperview))) targetType=\(String(describing: type(of: container)))"
        )
#endif
        for view in relatedSubviews {
            if view === container || view.isDescendant(of: container) {
                continue
            }
            let className = String(describing: type(of: view))
            let targetFrame: NSRect
            let currentSuperview = view.superview
            if preserveSlotLocalFrames && currentSuperview === sourceSuperview {
                targetFrame = view.frame
                reusedSourceLocalFrames = true
            } else {
                let frameInWindow = currentSuperview?.convert(view.frame, to: nil)
                    ?? sourceSuperview.convert(view.frame, to: nil)
                targetFrame = container.convert(frameInWindow, from: nil)
            }
            view.removeFromSuperview()
            container.addSubview(view, positioned: .above, relativeTo: nil)
            view.frame = targetFrame
            movedSubviewCount += 1
#if DEBUG
            cmuxDebugLog(
                "browser.localHost.reparent.batch.item reason=\(reason) class=\(className) " +
                "view=\(Self.objectID(view))"
            )
#endif
        }
        guard movedSubviewCount > 0 else { return }
        if reusedSourceLocalFrames, sourceSlotBoundsSize != container.bounds.size {
            container.resizeSubviews(withOldSize: sourceSlotBoundsSize)
            container.needsLayout = true
            container.layoutSubtreeIfNeeded()
        }
    }

    private static func installPortalAnchorView(_ anchorView: NSView, in host: NSView) {
        // Split reparenting can keep transient replacement hosts alive off-window.
        // reparenting. Never let those hosts steal the shared portal anchor, or the
        // portal will bind against an anchor with no real window and WKWebView will
        // fall into a hidden/unrendered state.
        guard host.window != nil else { return }
        if anchorView.superview !== host {
            anchorView.removeFromSuperview()
            anchorView.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(anchorView)
            NSLayoutConstraint.activate([
                anchorView.topAnchor.constraint(equalTo: host.topAnchor),
                anchorView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                anchorView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                anchorView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            ])
        } else if anchorView.translatesAutoresizingMaskIntoConstraints {
            anchorView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                anchorView.topAnchor.constraint(equalTo: host.topAnchor),
                anchorView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                anchorView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                anchorView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            ])
        }
        host.layoutSubtreeIfNeeded()
    }

    private func schedulePortalLifecycleVisibilityUpdate(
        coordinator: Coordinator,
        generation: Int,
        visibleInUI: Bool,
        reason: String,
        requireDesiredVisibilityMatch: Bool = true
    ) {
        let browserPanel = panel
        Task { @MainActor [weak coordinator] in
            guard let coordinator else { return }
            guard coordinator.attachGeneration == generation else { return }
            guard !requireDesiredVisibilityMatch ||
                coordinator.desiredPortalVisibleInUI == visibleInUI else { return }
            browserPanel.noteWebViewVisibility(visibleInUI, reason: reason)
        }
    }

    private func updateUsingLocalInlineHosting(
        _ nsView: NSView,
        coordinator: Coordinator,
        webView: WKWebView
    ) -> Bool {
        guard let host = nsView as? HostContainerView else { return false }
        let slotView = host.ensureLocalInlineSlotView()
        slotView.setDesignComposer(designComposer)
        let isAlreadyInLocalHost = host.containsManagedLocalInlineContent(webView)
        let shouldPreserveExternalFullscreenHost = Self.shouldPreserveExternalFullscreenHost(
            for: webView,
            relativeTo: host.window
        )
        let didAttachWebViewToLocalHost =
            !isAlreadyInLocalHost && !shouldPreserveExternalFullscreenHost

        coordinator.desiredPortalVisibleInUI = false
        coordinator.desiredPortalZPriority = 0
        coordinator.attachGeneration += 1

        if panel.releasePortalHostIfOwned(
            hostId: ObjectIdentifier(host),
            reason: "localInlineHosting"
        ) {
            BrowserWindowPortalRegistry.discard(
                webView: webView,
                source: "viewStateChanged.localInlineHosting",
                preserveCurrentSuperview: true
            )
        }

        let shouldPreserveExistingExternalLocalHost =
            host.window == nil &&
            webView.cmuxBrowserViewportAttachmentSuperview != nil &&
            !host.containsManagedLocalInlineContent(webView)
        if shouldPreserveExistingExternalLocalHost {
            // Split zoom can instantiate a replacement local host before it joins a window.
            // Never let that off-window host steal the live page + inspector hierarchy away
            // from the currently visible local host.
            host.setLocalInlineSlotHidden(true)
            coordinator.lastPortalHostId = nil
            coordinator.lastSynchronizedHostGeometryRevision = 0
#if DEBUG
            cmuxDebugLog(
                "browser.localHost.reparent.skip web=\(Self.objectID(webView)) " +
                "reason=offWindowReplacementHost super=\(Self.objectID(webView.superview)) " +
                "host=\(Self.objectID(host)) slot=\(Self.objectID(slotView))"
            )
            Self.logDevToolsState(
                panel,
                event: "localHost.skip",
                generation: coordinator.attachGeneration,
                retryCount: 0,
                details: Self.attachContext(webView: webView, host: host)
            )
#endif
            return false
        }

#if DEBUG
        if shouldPreserveExternalFullscreenHost {
            cmuxDebugLog(
                "browser.localHost.reparent.skip web=\(Self.objectID(webView)) " +
                "reason=fullscreenExternalHost host=\(Self.objectID(host)) " +
                "slot=\(Self.objectID(slotView)) state=\(String(describing: webView.fullscreenState))"
            )
        }
#endif

        host.setPreferredHostedInspectorWidth(width: nil, widthFraction: nil)
        host.setHostedInspectorFrontendWebView(nil)
        host.onPreferredHostedInspectorWidthChanged = nil
        slotView.onHostedInspectorLayout = { [weak host] _ in
            host?.scheduleHostedInspectorDividerReapply(reason: "slot.layout")
            host?.scheduleHostedInspectorDockConfigurationSync(reason: "slot.layout")
        }

        if didAttachWebViewToLocalHost {
            if let sourceSuperview = Self.localInlineTransferRoot(for: webView) {
                Self.moveWebKitRelatedSubviewsIntoHostIfNeeded(
                    from: sourceSuperview,
                    to: slotView,
                    primaryWebView: webView,
                    reason: "attachLocalHost"
                )
            } else {
                slotView.addSubview(
                    webView.cmuxBrowserViewportPresentationView,
                    positioned: .above,
                    relativeTo: nil
                )
            }
        }

        slotView.isHidden = false
        host.pinHostedWebView(
            webView,
            in: host.currentHostedWebViewContainer(preferredSlotView: slotView)
        )
        // Local-inline hosting takes ownership of the live WKWebView hierarchy.
        // Drop any stale portal entry once local-inline hosting owns the live
        // WKWebView hierarchy so deferred portal recovery cannot mutate the
        // browser after workspace switches.
        BrowserWindowPortalRegistry.discard(
            webView: webView,
            source: "viewStateChanged.localInlineHosting",
            preserveCurrentSuperview: true
        )
        coordinator.lastPortalHostId = nil
        coordinator.lastSynchronizedHostGeometryRevision = 0
        if host.window != nil && !shouldPreserveExternalFullscreenHost {
            let wasDeveloperToolsVisible = panel.isDeveloperToolsVisible()
            panel.noteDeveloperToolsHostAttached()
            panel.restoreDeveloperToolsAfterAttachIfNeeded()
            if let sourceSuperview = Self.localInlineTransferRoot(for: webView),
               didAttachWebViewToLocalHost || sourceSuperview === slotView {
                Self.moveWebKitRelatedSubviewsIntoHostIfNeeded(
                    from: sourceSuperview,
                    to: slotView,
                    primaryWebView: webView,
                    reason: didAttachWebViewToLocalHost
                        ? "localInline.reconcile.immediate"
                        : "localInline.reconcile.existingHost"
                )
            }
            host.setHostedInspectorFrontendWebView(nil)
            let didRevealDeveloperToolsAfterAttach =
                !wasDeveloperToolsVisible && panel.isDeveloperToolsVisible()
            webView.needsLayout = true
            webView.layoutSubtreeIfNeeded()
            slotView.layoutSubtreeIfNeeded()
            host.layoutSubtreeIfNeeded()
            host.refreshHostedWebKitPresentation(
                reason: didAttachWebViewToLocalHost
                    ? "localInline.update.immediate"
                    : "localInline.update.existingHost",
                forceLifecycleRefresh: didRevealDeveloperToolsAfterAttach
            )
            host.normalizeHostedInspectorLayoutIfNeeded(
                reason: didAttachWebViewToLocalHost
                    ? "localInline.update.immediate"
                    : "localInline.update.existingHost"
            )
            host.scheduleHostedInspectorDividerReapply(
                reason: didAttachWebViewToLocalHost
                    ? "localInline.update.sync"
                    : "localInline.update.existingHost"
            )
            Task { @MainActor [weak host, weak webView] in
                await Task.yield()
                guard let host, let webView else { return }
#if DEBUG
                let slotFrame = host.localInlineSlotViewForDebug()?.frame ?? .zero
                let companions = webView.superview?.subviews
                    .filter { $0 !== webView }
                    .map { String(describing: type(of: $0)) }
                    .joined(separator: ",") ?? "-"
                cmuxDebugLog(
                    "browser.localInline.frames host=\(host.bounds) slot=\(slotFrame) " +
                    "web=\(webView.frame) webSuper=\(String(describing: type(of: webView.superview))) " +
                    "inspector=0 " +
                    "companions=\(companions)"
                )
#endif
                if let sourceSuperview = Self.localInlineTransferRoot(for: webView),
                   sourceSuperview === slotView {
                    Self.moveWebKitRelatedSubviewsIntoHostIfNeeded(
                        from: sourceSuperview,
                        to: slotView,
                        primaryWebView: webView,
                        reason: "localInline.reconcile.async"
                    )
                }
                host.setHostedInspectorFrontendWebView(nil)
                host.refreshHostedWebKitPresentation(
                    reason: didAttachWebViewToLocalHost
                        ? "localInline.update.async"
                        : "localInline.update.existingHost.async",
                    forceLifecycleRefresh: didRevealDeveloperToolsAfterAttach
                )
                host.scheduleHostedInspectorDockConfigurationSync(
                    reason: didAttachWebViewToLocalHost
                        ? "localInline.update.async"
                        : "localInline.update.existingHost.async"
                )
            }
        } else if !shouldPreserveExternalFullscreenHost {
            panel.consumeAttachedDeveloperToolsManualCloseIfNeeded()
            host.scheduleHostedInspectorDockConfigurationSync(reason: "localInline.update")
        }

#if DEBUG
        Self.logDevToolsState(
            panel,
            event: "localHost.update",
            generation: coordinator.attachGeneration,
            retryCount: 0,
            details: Self.attachContext(webView: webView, host: host)
        )
#endif
        return !shouldPreserveExternalFullscreenHost
    }

    private func updateUsingWindowPortal(
        _ nsView: NSView,
        coordinator: Coordinator,
        webView: WKWebView
    ) -> Bool {
        guard let host = nsView as? HostContainerView else { return false }
        host.prepareForWindowPortalHosting()
        host.setLocalInlineSlotHidden(true)
        host.releaseHostedWebViewConstraints()
        let shouldPreserveExternalFullscreenHost = Self.shouldPreserveExternalFullscreenHost(
            for: webView,
            relativeTo: host.window
        )

        let paneDropContext = currentPaneDropContext()
        let isCurrentPaneOwner = paneDropContext?.paneId.id == paneId.id
        let hostId = ObjectIdentifier(host)
        let previousVisible = coordinator.desiredPortalVisibleInUI
        let previousZPriority = coordinator.desiredPortalZPriority
        coordinator.desiredPortalVisibleInUI = shouldAttachWebView && isCurrentPaneOwner
        coordinator.desiredPortalZPriority = portalZPriority
        coordinator.attachGeneration += 1
        let generation = coordinator.attachGeneration
        let activePaneDropContext = coordinator.desiredPortalVisibleInUI ? paneDropContext : nil
        let activeSearchOverlay = coordinator.desiredPortalVisibleInUI ? searchOverlay : nil
        let activeDesignComposer = coordinator.desiredPortalVisibleInUI ? designComposer : nil
        let portalAnchorView = panel.portalAnchorView
        let portalHideReason = !isCurrentPaneOwner ? "lostPaneOwnership" : "hidden"
        let didReleasePortalHost: Bool
        if !shouldAttachWebView || !isCurrentPaneOwner {
            didReleasePortalHost = panel.releasePortalHostIfOwned(
                hostId: hostId,
                reason: portalHideReason
            )
            // Only the host that currently owns the portal is allowed to hide it.
            // Older keep-alive hosts can still receive updates after a new owner binds.
            if didReleasePortalHost {
                BrowserWindowPortalRegistry.hide(
                    webView: webView,
                    source: "viewStateChanged.\(portalHideReason)"
                )
            }
        } else {
            didReleasePortalHost = false
        }
        let portalHostAccepted =
            shouldAttachWebView &&
            isCurrentPaneOwner &&
            panel.claimPortalHost(
                hostId: hostId,
                paneId: paneId,
                inWindow: host.window != nil,
                bounds: host.bounds,
                reason: "update"
            )
        if portalHostAccepted || didReleasePortalHost {
            let lifecycleVisibleInUI = portalHostAccepted && coordinator.desiredPortalVisibleInUI
            let lifecycleReason = lifecycleVisibleInUI ? "portal.update.visible" : "portal.update.hidden"
            schedulePortalLifecycleVisibilityUpdate(
                coordinator: coordinator,
                generation: generation,
                visibleInUI: lifecycleVisibleInUI,
                reason: lifecycleReason,
                requireDesiredVisibilityMatch: portalHostAccepted
            )
        }
#if DEBUG
        if !isCurrentPaneOwner && (shouldAttachWebView || host.window != nil) {
            cmuxDebugLog(
                "browser.portal.owner.skip panel=\(panel.id.uuidString.prefix(5)) " +
                "viewPane=\(paneId.id.uuidString.prefix(5)) " +
                "currentPane=\(paneDropContext?.paneId.id.uuidString.prefix(5) ?? "nil") " +
                "host=\(Self.objectID(host)) hostInWin=\(host.window != nil ? 1 : 0) " +
                "released=\(didReleasePortalHost ? 1 : 0)"
            )
        }
#endif
        if host.window != nil, portalHostAccepted {
            Self.installPortalAnchorView(portalAnchorView, in: host)
        }
        let activeOmnibarSuggestions = coordinator.desiredPortalVisibleInUI ? omnibarSuggestions : nil

        host.onDidMoveToWindow = { [weak host, weak webView, weak coordinator, weak portalAnchorView, weak browserPanel = panel] in
            guard let host, let webView, let coordinator, let portalAnchorView, let browserPanel else { return }
            guard coordinator.attachGeneration == generation else { return }
            guard currentPaneDropContext()?.paneId.id == paneId.id else { return }
            guard browserPanel.claimPortalHost(
                hostId: ObjectIdentifier(host),
                paneId: paneId,
                inWindow: host.window != nil,
                bounds: host.bounds,
                reason: "didMoveToWindow"
            ) else { return }
            guard host.window != nil else { return }
            Self.installPortalAnchorView(portalAnchorView, in: host)
            BrowserWindowPortalRegistry.bind(
                webView: webView,
                to: portalAnchorView,
                visibleInUI: coordinator.desiredPortalVisibleInUI,
                zPriority: coordinator.desiredPortalZPriority
            )
            BrowserWindowPortalRegistry.refresh(
                webView: webView,
                reason: "portalHostBind.didMoveToWindow"
            )
            BrowserWindowPortalRegistry.updatePaneTopChromeHeight(
                for: webView,
                height: coordinator.desiredPortalVisibleInUI ? paneTopChromeHeight : 0
            )
            BrowserWindowPortalRegistry.updatePaneDropContext(for: webView, context: activePaneDropContext)
            BrowserWindowPortalRegistry.updateSearchOverlay(for: webView, configuration: activeSearchOverlay)
            BrowserWindowPortalRegistry.updateDesignComposer(for: webView, configuration: activeDesignComposer)
            BrowserWindowPortalRegistry.updateOmnibarSuggestions(for: webView, configuration: activeOmnibarSuggestions)
            coordinator.lastPortalHostId = ObjectIdentifier(host)
            coordinator.lastSynchronizedHostGeometryRevision = host.geometryRevision
        }
        host.onGeometryChanged = { [weak host, weak webView, weak coordinator, weak portalAnchorView, weak browserPanel = panel] in
            guard let host, let webView, let coordinator, let portalAnchorView, let browserPanel else { return }
            guard coordinator.attachGeneration == generation else { return }
            guard currentPaneDropContext()?.paneId.id == paneId.id else { return }
            guard browserPanel.claimPortalHost(
                hostId: ObjectIdentifier(host),
                paneId: paneId,
                inWindow: host.window != nil,
                bounds: host.bounds,
                reason: "geometryChanged"
            ) else { return }
            guard host.window != nil else { return }
            let hostId = ObjectIdentifier(host)
            Self.installPortalAnchorView(portalAnchorView, in: host)
            if coordinator.lastPortalHostId != hostId ||
               !BrowserWindowPortalRegistry.isWebView(webView, boundTo: portalAnchorView) {
                BrowserWindowPortalRegistry.bind(
                    webView: webView,
                    to: portalAnchorView,
                    visibleInUI: coordinator.desiredPortalVisibleInUI,
                    zPriority: coordinator.desiredPortalZPriority
                )
                BrowserWindowPortalRegistry.refresh(
                    webView: webView,
                    reason: "portalHostBind.geometryChanged"
                )
                BrowserWindowPortalRegistry.updatePaneTopChromeHeight(
                    for: webView,
                    height: coordinator.desiredPortalVisibleInUI ? paneTopChromeHeight : 0
                )
                BrowserWindowPortalRegistry.updatePaneDropContext(for: webView, context: activePaneDropContext)
                BrowserWindowPortalRegistry.updateSearchOverlay(for: webView, configuration: activeSearchOverlay)
                BrowserWindowPortalRegistry.updateDesignComposer(for: webView, configuration: activeDesignComposer)
                BrowserWindowPortalRegistry.updateOmnibarSuggestions(for: webView, configuration: activeOmnibarSuggestions)
                coordinator.lastPortalHostId = hostId
            }
            BrowserWindowPortalRegistry.synchronizeForAnchor(portalAnchorView)
            coordinator.lastSynchronizedHostGeometryRevision = host.geometryRevision
        }

        if !shouldAttachWebView {
            // In portal mode we no longer detach/re-attach to preserve DevTools state.
            // Sync the inspector preference directly so manual closes are respected.
            panel.syncDeveloperToolsPreferenceFromInspector(
                preserveVisibleIntent: panel.shouldPreserveDeveloperToolsIntentWhileDetached()
            )
        }

        if host.window != nil, portalHostAccepted {
            let geometryRevision = host.geometryRevision
            let portalEntryMissing = !BrowserWindowPortalRegistry.isWebView(webView, boundTo: portalAnchorView)
            let shouldBindNow =
                coordinator.lastPortalHostId != hostId ||
                webView.cmuxBrowserViewportAttachmentSuperview == nil ||
                portalEntryMissing ||
                previousVisible != shouldAttachWebView ||
                previousZPriority != portalZPriority
            if shouldBindNow {
                Self.installPortalAnchorView(portalAnchorView, in: host)
                BrowserWindowPortalRegistry.bind(
                    webView: webView,
                    to: portalAnchorView,
                    visibleInUI: coordinator.desiredPortalVisibleInUI,
                    zPriority: coordinator.desiredPortalZPriority
                )
                // Force a rendering-state reattach after portal host replacement
                // (e.g. after a pane split). Without this, WKWebView can freeze
                // because _exitInWindow/_enterInWindow are never cycled when the
                // web view is reparented to a new container during bind.
                BrowserWindowPortalRegistry.refresh(
                    webView: webView,
                    reason: "portalHostBind"
                )
                coordinator.lastPortalHostId = hostId
                coordinator.lastSynchronizedHostGeometryRevision = geometryRevision
            }
            BrowserWindowPortalRegistry.updatePaneTopChromeHeight(
                for: webView,
                height: coordinator.desiredPortalVisibleInUI ? paneTopChromeHeight : 0
            )
            BrowserWindowPortalRegistry.updateSearchOverlay(for: webView, configuration: activeSearchOverlay)
            BrowserWindowPortalRegistry.updateDesignComposer(for: webView, configuration: activeDesignComposer)
            BrowserWindowPortalRegistry.updateOmnibarSuggestions(for: webView, configuration: activeOmnibarSuggestions)
            if !shouldBindNow,
               coordinator.lastSynchronizedHostGeometryRevision != geometryRevision {
                BrowserWindowPortalRegistry.synchronizeForAnchor(portalAnchorView)
                coordinator.lastSynchronizedHostGeometryRevision = geometryRevision
            }
        } else if portalHostAccepted {
            // Bind is deferred until host moves into a window. Keep the current
            // portal entry's desired state in sync so stale callbacks cannot keep
            // the previous anchor visible while this host is temporarily off-window.
            BrowserWindowPortalRegistry.updateEntryVisibility(
                for: webView,
                visibleInUI: coordinator.desiredPortalVisibleInUI,
                zPriority: coordinator.desiredPortalZPriority
            )
        }

        if portalHostAccepted {
            BrowserWindowPortalRegistry.updateDropZoneOverlay(
                for: webView,
                zone: coordinator.desiredPortalVisibleInUI ? paneDropZone : nil
            )
            BrowserWindowPortalRegistry.updatePaneTopChromeHeight(
                for: webView,
                height: coordinator.desiredPortalVisibleInUI ? paneTopChromeHeight : 0
            )
            BrowserWindowPortalRegistry.updatePaneDropContext(
                for: webView,
                context: activePaneDropContext
            )
            BrowserWindowPortalRegistry.updateSearchOverlay(for: webView, configuration: activeSearchOverlay)
            BrowserWindowPortalRegistry.updateDesignComposer(for: webView, configuration: activeDesignComposer)
            BrowserWindowPortalRegistry.updateOmnibarSuggestions(for: webView, configuration: activeOmnibarSuggestions)
        }

        panel.restoreDeveloperToolsAfterAttachIfNeeded()

        #if DEBUG
        Self.logDevToolsState(
            panel,
            event: "portal.update",
            generation: coordinator.attachGeneration,
            retryCount: 0,
            details: Self.attachContext(webView: webView, host: host)
        )
        #endif
        return portalHostAccepted && !shouldPreserveExternalFullscreenHost
    }

    func updateNativeView(_ nsView: NSView, coordinator: Coordinator) {
        let webView = panel.webView
        let isCurrentPaneOwner = currentPaneDropContext()?.paneId.id == paneId.id
        if let previousWebView = coordinator.webView, previousWebView !== webView {
            BrowserWindowPortalRegistry.detach(webView: previousWebView)
            coordinator.lastPortalHostId = nil
            coordinator.lastSynchronizedHostGeometryRevision = 0
        }
        coordinator.panel = panel
        coordinator.webView = webView

        Self.clearPortalCallbacks(for: nsView)
        let hostOwnsPortal = useLocalInlineHosting
            ? updateUsingLocalInlineHosting(nsView, coordinator: coordinator, webView: webView)
            : updateUsingWindowPortal(nsView, coordinator: coordinator, webView: webView)
        if hostOwnsPortal {
            panel.releaseBackgroundPreloadHostIfAttachedToRealWindow(reason: "representable.update")
        }
        Self.applyWebViewFirstResponderPolicy(
            panel: panel,
            webView: webView,
            isPanelFocused: isPanelFocused && isCurrentPaneOwner && hostOwnsPortal
        )

        Self.applyFocus(
            panel: panel,
            webView: webView,
            nsView: nsView,
            shouldFocusWebView: shouldFocusWebView && isCurrentPaneOwner && hostOwnsPortal,
            isPanelFocused: isPanelFocused && isCurrentPaneOwner && hostOwnsPortal
        )
    }

    private static func applyFocus(
        panel: BrowserPanel,
        webView: WKWebView,
        nsView: NSView,
        shouldFocusWebView: Bool,
        isPanelFocused: Bool
    ) {
        // Focus handling. Avoid fighting the address bar when it is focused.
        guard let window = nsView.window else {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.content.apply panel=\(panel.id.uuidString.prefix(5)) " +
                "action=skip reason=no_window shouldFocus=\(shouldFocusWebView ? 1 : 0) " +
                "panelFocused=\(isPanelFocused ? 1 : 0)"
            )
#endif
            return
        }
        if isPanelFocused && responderChainContains(window.firstResponder, target: webView) {
            if panel.shouldSuppressWebViewFocus() {
#if DEBUG
                cmuxDebugLog(
                    "browser.focus.content.apply panel=\(panel.id.uuidString.prefix(5)) " +
                    "action=skip_webview_intent reason=suppressed_first_responder_chain"
                )
#endif
            } else {
                panel.noteWebViewFocused()
            }
        }
        if shouldFocusWebView {
            if panel.shouldSuppressWebViewFocus() {
#if DEBUG
                cmuxDebugLog(
                    "browser.focus.content.apply panel=\(panel.id.uuidString.prefix(5)) " +
                    "action=skip reason=suppressed panelFocused=\(isPanelFocused ? 1 : 0)"
                )
#endif
                return
            }
            if responderChainContains(window.firstResponder, target: webView) {
#if DEBUG
                cmuxDebugLog(
                    "browser.focus.content.apply panel=\(panel.id.uuidString.prefix(5)) " +
                    "action=skip reason=already_first_responder_chain"
                )
#endif
                return
            }
            let result = window.makeFirstResponder(webView)
            if result {
                panel.noteWebViewFocused()
            }
#if DEBUG
            cmuxDebugLog(
                "browser.focus.content.apply panel=\(panel.id.uuidString.prefix(5)) " +
                "action=focus result=\(result ? 1 : 0) fr=\(responderDescription(window.firstResponder))"
            )
#endif
        } else if !isPanelFocused && responderChainContains(window.firstResponder, target: webView) {
            // Only force-resign WebView focus when this panel itself is not focused.
            // If the panel is focused but the omnibar-focus state is briefly stale, aggressively
            // clearing first responder here can undo programmatic webview focus (socket tests).
            let result = window.makeFirstResponder(nil)
#if DEBUG
            cmuxDebugLog(
                "browser.focus.content.apply panel=\(panel.id.uuidString.prefix(5)) " +
                "action=resign result=\(result ? 1 : 0) fr=\(responderDescription(window.firstResponder))"
            )
#endif
        }
    }

    private static func applyWebViewFirstResponderPolicy(
        panel: BrowserPanel,
        webView: WKWebView,
        isPanelFocused: Bool
    ) {
        guard let cmuxWebView = webView as? CmuxWebView else { return }
        let next = isPanelFocused && !panel.shouldSuppressWebViewFocus()
        if cmuxWebView.allowsFirstResponderAcquisition != next {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.policy panel=\(panel.id.uuidString.prefix(5)) " +
                "web=\(ObjectIdentifier(cmuxWebView)) old=\(cmuxWebView.allowsFirstResponderAcquisition ? 1 : 0) " +
                "new=\(next ? 1 : 0) isPanelFocused=\(isPanelFocused ? 1 : 0) " +
                "suppress=\(panel.shouldSuppressWebViewFocus() ? 1 : 0)"
            )
#endif
        }
        cmuxWebView.allowsFirstResponderAcquisition = next
    }

    static func dismantleNativeView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.attachGeneration += 1
        clearPortalCallbacks(for: nsView)
        if let panel = coordinator.panel, let host = nsView as? HostContainerView {
            panel.releasePortalHostIfOwned(
                hostId: ObjectIdentifier(host),
                reason: "dismantle"
            )
        }

        guard let webView = coordinator.webView else { return }
        let panel = coordinator.panel

        // If we're being torn down while the WKWebView (or one of its subviews) is first responder,
        // resign it before detaching.
        let window = webView.window ?? nsView.window
        if let window {
            let state = firstResponderResignState(window.firstResponder, webView: webView)
            if state.needsResign {
                #if DEBUG
                if let panel {
                    logDevToolsState(
                        panel,
                        event: "dismantle.resignFirstResponder",
                        generation: coordinator.attachGeneration,
                        retryCount: 0,
                        details: attachContext(webView: webView, host: nsView) + " " + state.flags
                    )
                }
                #endif
                window.makeFirstResponder(nil)
            }
        }

        // Split rearrangement can transiently replace the browser host view. Do not detach
        // the portal-hosted WKWebView or clear its pane-drop context here; explicit teardown
        // still happens on real web view replacement and panel teardown, and preserving this
        // state lets internal tab drags re-enter the browser pane while hosts settle.
        BrowserWindowPortalRegistry.updateDropZoneOverlay(for: webView, zone: nil)
        coordinator.lastPortalHostId = nil
        coordinator.lastSynchronizedHostGeometryRevision = 0
    }

    private func currentPaneDropContext() -> BrowserPaneDropContext? {
        // Dock-hosted browsers are not registered in the Workspace tree, so the
        // workspace lookup below can't resolve their pane. `paneId` is already the
        // Dock's own Bonsplit pane id, so the drop target diverts live-surface tab
        // drops to the Dock via `dockForPane`/`performPortalPaneDrop` (mirroring
        // the terminal pane drop target). A browser filling the Dock now accepts
        // drops instead of rejecting them.
        if let paneOwnershipOverride {
            guard paneOwnershipOverride else { return nil }
            return BrowserPaneDropContext(
                workspaceId: panel.workspaceId,
                panelId: panel.id,
                paneId: paneId
            )
        }
        guard let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: panel.workspaceId),
              let workspace = manager.tabs.first(where: { $0.id == panel.workspaceId }),
              let resolvedPaneId = workspace.paneId(forPanelId: panel.id) else {
            return nil
        }
        return BrowserPaneDropContext(
            workspaceId: panel.workspaceId,
            panelId: panel.id,
            paneId: resolvedPaneId
        )
    }
}
