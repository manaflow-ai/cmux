public import Foundation

/// Pure omnibar matching/scoring over browser history. Stateless: every method
/// is a deterministic transform of its inputs (entry fields plus the query and
/// a `now` for recency decay), so it is `Sendable` and trivially unit-testable
/// with fixed clocks and no filesystem.
///
/// The owning store builds candidates once via ``candidate(for:)``, caches
/// them, then ranks each keystroke through
/// ``score(candidate:query:queryTokens:now:)`` using the tokens from
/// ``tokenize(query:)``. Scoring blends literal/prefix/substring matches on
/// host, URL, path, and title with a frecency component (recency decay plus
/// log-scaled visit and typed counts).
public struct BrowserHistorySuggestionEngine: Sendable {
    /// Creates a scoring engine. The engine holds no state.
    public init() {}

    /// Precomputes the lowercased/parsed match fields for `entry`.
    public func candidate(for entry: BrowserHistoryEntry) -> BrowserHistorySuggestionCandidate {
        let urlLower = entry.url.lowercased()
        let urlSansSchemeLower = Self.strippingHTTPSSchemePrefix(urlLower)
        let components = URLComponents(string: entry.url)
        let hostLower = components?.host?.lowercased() ?? ""
        let path = (components?.percentEncodedPath ?? components?.path ?? "").lowercased()
        let query = (components?.percentEncodedQuery ?? components?.query ?? "").lowercased()
        let pathAndQueryLower: String
        if query.isEmpty {
            pathAndQueryLower = path
        } else {
            pathAndQueryLower = "\(path)?\(query)"
        }
        let titleLower = (entry.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return BrowserHistorySuggestionCandidate(
            entry: entry,
            urlLower: urlLower,
            urlSansSchemeLower: urlSansSchemeLower,
            hostLower: hostLower,
            pathAndQueryLower: pathAndQueryLower,
            titleLower: titleLower
        )
    }

    /// Scores `candidate` against a normalized lowercased `query` and its
    /// `queryTokens`, returning `nil` when the candidate does not match.
    /// Single-character queries require a strong (prefix) match; otherwise any
    /// substring or all-token match qualifies. `now` drives the recency decay.
    public func score(
        candidate: BrowserHistorySuggestionCandidate,
        query: String,
        queryTokens: [String],
        now: Date
    ) -> Double? {
        let queryIncludesScheme = query.hasPrefix("http://") || query.hasPrefix("https://")
        let urlMatchValue = queryIncludesScheme ? candidate.urlLower : candidate.urlSansSchemeLower
        let isSingleCharacterQuery = query.count == 1
        if isSingleCharacterQuery {
            let hasSingleCharStrongMatch =
                candidate.hostLower.hasPrefix(query) ||
                candidate.titleLower.hasPrefix(query) ||
                urlMatchValue.hasPrefix(query)
            guard hasSingleCharStrongMatch else { return nil }
        }

        let queryMatches =
            urlMatchValue.contains(query) ||
            candidate.hostLower.contains(query) ||
            candidate.pathAndQueryLower.contains(query) ||
            candidate.titleLower.contains(query)

        let tokenMatches = !queryTokens.isEmpty && queryTokens.allSatisfy { token in
            candidate.urlSansSchemeLower.contains(token) ||
            candidate.hostLower.contains(token) ||
            candidate.pathAndQueryLower.contains(token) ||
            candidate.titleLower.contains(token)
        }

        guard queryMatches || tokenMatches else { return nil }

        var score = 0.0

        if urlMatchValue == query { score += 1200 }
        if candidate.hostLower == query { score += 980 }
        if candidate.hostLower.hasPrefix(query) { score += 680 }
        if urlMatchValue.hasPrefix(query) { score += 560 }
        if candidate.titleLower.hasPrefix(query) { score += 420 }
        if candidate.pathAndQueryLower.hasPrefix(query) { score += 300 }

        if candidate.hostLower.contains(query) { score += 210 }
        if candidate.pathAndQueryLower.contains(query) { score += 165 }
        if candidate.titleLower.contains(query) { score += 145 }

        for token in queryTokens {
            if candidate.hostLower == token { score += 260 }
            else if candidate.hostLower.hasPrefix(token) { score += 170 }
            else if candidate.hostLower.contains(token) { score += 110 }

            if candidate.pathAndQueryLower.hasPrefix(token) { score += 80 }
            else if candidate.pathAndQueryLower.contains(token) { score += 52 }

            if candidate.titleLower.hasPrefix(token) { score += 74 }
            else if candidate.titleLower.contains(token) { score += 48 }
        }

        // Blend recency and repeat visits so history feels closer to browser frecency.
        let ageHours = max(0, now.timeIntervalSince(candidate.entry.lastVisited) / 3600)
        let recencyScore = max(0, 110 - (ageHours / 3))
        let frequencyScore = min(120, log1p(Double(max(1, candidate.entry.visitCount))) * 38)
        let typedFrequencyScore = min(190, log1p(Double(max(0, candidate.entry.typedCount))) * 80)
        let typedRecencyScore: Double
        if let lastTypedAt = candidate.entry.lastTypedAt {
            let typedAgeHours = max(0, now.timeIntervalSince(lastTypedAt) / 3600)
            typedRecencyScore = max(0, 85 - (typedAgeHours / 4))
        } else {
            typedRecencyScore = 0
        }
        score += recencyScore + frequencyScore + typedFrequencyScore + typedRecencyScore

        return score
    }

    /// Splits a query into unique, order-preserving tokens on whitespace,
    /// punctuation, and symbols.
    public func tokenize(query: String) -> [String] {
        var tokens: [String] = []
        var seen = Set<String>()
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        for raw in query.components(separatedBy: separators) {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            guard !seen.contains(token) else { continue }
            seen.insert(token)
            tokens.append(token)
        }
        return tokens
    }

    /// Removes a leading `https://` or `http://` from `value`, returning it
    /// unchanged when neither prefix is present.
    public static func strippingHTTPSSchemePrefix(_ value: String) -> String {
        if value.hasPrefix("https://") {
            return String(value.dropFirst("https://".count))
        }
        if value.hasPrefix("http://") {
            return String(value.dropFirst("http://".count))
        }
        return value
    }

    /// The dedup key for an `http`/`https` `URL`: scheme, host with a leading
    /// `www.` stripped, default port dropped, trailing-slash-normalized path,
    /// and lowercased query. Returns `nil` for non-http(s) URLs or URLs without
    /// a host, matching the visit-dedup semantics of the history store.
    public func normalizedHistoryKey(url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        return Self.normalizedHistoryKey(components: &components)
    }

    /// The dedup key for a URL string, parsed via `URLComponents`. See
    /// ``normalizedHistoryKey(url:)``.
    public func normalizedHistoryKey(urlString: String) -> String? {
        guard var components = URLComponents(string: urlString) else { return nil }
        return Self.normalizedHistoryKey(components: &components)
    }

    private static func normalizedHistoryKey(components: inout URLComponents) -> String? {
        guard let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              var host = components.host?.lowercased() else {
            return nil
        }

        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }

        if (scheme == "http" && components.port == 80) ||
            (scheme == "https" && components.port == 443) {
            components.port = nil
        }

        let portPart: String
        if let port = components.port {
            portPart = ":\(port)"
        } else {
            portPart = ""
        }

        var path = components.percentEncodedPath
        if path.isEmpty { path = "/" }
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }

        let queryPart: String
        if let query = components.percentEncodedQuery, !query.isEmpty {
            queryPart = "?\(query.lowercased())"
        } else {
            queryPart = ""
        }

        return "\(scheme)://\(host)\(portPart)\(path)\(queryPart)"
    }
}
