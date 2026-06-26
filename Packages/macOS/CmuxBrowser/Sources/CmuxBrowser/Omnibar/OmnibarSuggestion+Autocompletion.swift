import Foundation

extension OmnibarSuggestion {
    /// The completion string used for inline autocompletion, or `nil` for kinds
    /// (search, remote) that never autocomplete the typed query.
    public var autocompletionCompletion: String? {
        switch kind {
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

    /// The title used when matching a typed prefix, or `nil` when the kind has
    /// no title to autocomplete against.
    public var autocompletionTitle: String? {
        switch kind {
        case .history(_, let title):
            return title
        case .switchToTab(_, _, _, let title):
            return title
        default:
            return nil
        }
    }

    /// Whether this suggestion can inline-autocomplete the given typed query: the
    /// kind must be autocompletable, its host must carry a TLD, and either its
    /// completion or title must extend the typed prefix.
    public func supportsAutocompletion(query: String) -> Bool {
        if case .search = kind { return false }
        if case .remote = kind { return false }
        guard let completion = autocompletionCompletion else { return false }
        // Reject URLs whose host lacks a TLD (e.g. "https://news." → host "news").
        if let components = URLComponents(string: completion),
           let host = components.host?.lowercased() {
            let trimmedHost = host.hasSuffix(".") ? String(host.dropLast()) : host
            if !trimmedHost.contains(".") { return false }
        }
        let title = autocompletionTitle
        return Self.matchesTypedPrefix(
            typedText: query,
            suggestionCompletion: completion,
            suggestionTitle: title
        )
    }

    /// Whether `suggestionCompletion` (or `suggestionTitle`) begins with the
    /// typed text, honoring scheme/`www.` prefix normalization.
    public static func matchesTypedPrefix(
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

        let schemeStripped = trimmedCompletion.strippingHTTPSchemePrefix
        let schemeAndWWWStripped = trimmedCompletion.strippingHTTPSchemeAndWWWPrefix
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

    /// The index of the suggestion that should be promoted for inline
    /// autocompletion (shortest matching suffix wins, ties broken by order), or
    /// `nil` when none qualifies.
    public static func preferredAutocompletionIndex(
        in suggestions: [OmnibarSuggestion],
        query: String
    ) -> Int? {
        guard !query.isEmpty else { return nil }

        var candidates: [(idx: Int, suffixLength: Int)] = []
        for (idx, suggestion) in suggestions.enumerated() {
            guard suggestion.supportsAutocompletion(query: query) else { continue }
            guard let completion = suggestion.autocompletionCompletion else { continue }
            let displayCompletion = matchesTypedPrefix(
                typedText: query,
                suggestionCompletion: completion,
                suggestionTitle: suggestion.autocompletionTitle
            ) ? completion : ""
            guard !displayCompletion.isEmpty else { continue }

            let suffixLength = max(
                0,
                autocompletionDisplayText(forPrefixing: displayCompletion, query: query).utf16.count - query.utf16.count
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

    /// Whether a single-character `query` prefix-matches the candidate `url` (after
    /// scheme/`www.` stripping) or `title`. Returns `false` for empty or
    /// multi-character queries. Drives the single-letter omnibar suggestion filter.
    public static func hasSingleCharacterPrefixMatch(query: String, url: String, title: String?) -> Bool {
        guard let trimmedQuery = query.omnibarSingleCharacterQuery else { return false }

        let normalizedURL = url.strippingHTTPSchemeAndWWWPrefix.lowercased()
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return normalizedURL.hasPrefix(trimmedQuery) || normalizedTitle.hasPrefix(trimmedQuery)
    }

    private static func autocompletionDisplayText(forPrefixing completion: String, query: String) -> String {
        let typedIncludesScheme = query.hasPrefix("https://") || query.hasPrefix("http://")
        let typedIncludesWWWPrefix = query.hasPrefix("www.")
        if typedIncludesScheme {
            return completion
        }
        if typedIncludesWWWPrefix {
            return completion.strippingHTTPSchemePrefix
        }
        return completion.strippingHTTPSchemeAndWWWPrefix
    }
}
