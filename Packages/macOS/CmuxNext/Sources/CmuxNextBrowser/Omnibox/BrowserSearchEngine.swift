public import Foundation

/// A web search engine the address bar falls back to.
public nonisolated struct BrowserSearchEngine: Hashable, Sendable, Codable, Identifiable {
    public static let placeholder = "{searchTerms}"

    /// Chrome's spelling of the placeholder, accepted in custom templates.
    public static let chromePlaceholder = "%s"

    public var id: String
    public var name: String
    /// URL with `{searchTerms}` where the encoded query goes.
    public var queryTemplate: String
    /// The suggest endpoint (OpenSearch JSON: `[query, [suggestion, ...]]`),
    /// with `{searchTerms}` for the typed text; nil when the engine has none.
    public var suggestTemplate: String?

    public init(id: String, name: String, queryTemplate: String, suggestTemplate: String? = nil) {
        self.id = id
        self.name = name
        self.queryTemplate = queryTemplate.replacingOccurrences(of: Self.chromePlaceholder, with: Self.placeholder)
        self.suggestTemplate = suggestTemplate?.replacingOccurrences(of: Self.chromePlaceholder, with: Self.placeholder)
    }

    /// The search results URL for `query`, or nil for an empty query or a
    /// malformed template.
    public func searchURL(for query: String) -> URL? {
        Self.fill(queryTemplate, with: query)
    }

    /// The suggest request for `query`, or nil (no endpoint, empty query).
    public func suggestURL(for query: String) -> URL? {
        suggestTemplate.flatMap { Self.fill($0, with: query) }
    }

    private static func fill(_ template: String, with query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              template.contains(placeholder),
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) else {
            return nil
        }
        return URL(string: template.replacingOccurrences(of: placeholder, with: encoded))
    }

    /// RFC 3986 unreserved characters only, so `&`, `+`, `#`, `=` in the query
    /// never change the URL structure.
    private static let queryValueAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
    )

    public static let google = BrowserSearchEngine(
        id: "google", name: "Google", queryTemplate: "https://www.google.com/search?q={searchTerms}",
        suggestTemplate: "https://suggestqueries.google.com/complete/search?client=firefox&q={searchTerms}"
    )
    public static let duckDuckGo = BrowserSearchEngine(
        id: "duckduckgo", name: "DuckDuckGo", queryTemplate: "https://duckduckgo.com/?q={searchTerms}",
        suggestTemplate: "https://duckduckgo.com/ac/?q={searchTerms}&type=list"
    )
    public static let bing = BrowserSearchEngine(
        id: "bing", name: "Bing", queryTemplate: "https://www.bing.com/search?q={searchTerms}",
        suggestTemplate: "https://api.bing.com/osjson.aspx?query={searchTerms}"
    )
    public static let brave = BrowserSearchEngine(
        id: "brave", name: "Brave", queryTemplate: "https://search.brave.com/search?q={searchTerms}",
        suggestTemplate: "https://search.brave.com/api/suggest?q={searchTerms}"
    )
    public static let kagi = BrowserSearchEngine(
        id: "kagi", name: "Kagi", queryTemplate: "https://kagi.com/search?q={searchTerms}",
        suggestTemplate: "https://kagi.com/api/autosuggest?q={searchTerms}"
    )

    public static let builtIn: [BrowserSearchEngine] = [google, duckDuckGo, bing, brave, kagi]
    /// Each built-in engine's search address by id (an imported engine maps to the one with its host).
    public static var templates: [String: String] { Dictionary(uniqueKeysWithValues: builtIn.map { ($0.id, $0.queryTemplate) }) }

    /// A user's engine (`browser.customSearchEngine`): `search` and `suggest`
    /// take `{searchTerms}` or `%s`. Named after the search host.
    public static func custom(search: String, suggest: String?) -> BrowserSearchEngine {
        let host = URL(string: search.replacingOccurrences(of: chromePlaceholder, with: "x")
            .replacingOccurrences(of: placeholder, with: "x"))?.host() ?? search
        let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return BrowserSearchEngine(id: "custom", name: name, queryTemplate: search, suggestTemplate: suggest.flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// What the address bar does with submitted text.
public nonisolated enum OmniboxDestination: Hashable, Sendable {
    case url(URL)
    case search(query: String, url: URL)

    public var url: URL {
        switch self {
        case .url(let url), .search(_, let url): url
        }
    }
}

/// Combines URL resolution and search fallback.
public nonisolated struct OmniboxResolver: Sendable {
    public var urlResolver: BrowserURLResolver
    public var searchEngine: BrowserSearchEngine
    /// Extension omnibox keywords of the tab (`chrome.omnibox`); empty for
    /// WebKit tabs.
    public var keywords: [OmnibarKeyword]
    /// Typed hosts already fixed once (`HostTypoFixup`); shared by every
    /// copy of this resolver.
    public let hostTypoMemory: HostTypoMemory
    /// Bare words that resolved as intranet hosts (``IntranetHostProbe``);
    /// shared by every copy of this resolver.
    public let intranetHosts: IntranetHostMemory

    public init(urlResolver: BrowserURLResolver = BrowserURLResolver(), searchEngine: BrowserSearchEngine = .google,
                keywords: [OmnibarKeyword] = [], hostTypoMemory: HostTypoMemory = HostTypoMemory(),
                intranetHosts: IntranetHostMemory = IntranetHostMemory()) {
        self.urlResolver = urlResolver
        self.searchEngine = searchEngine
        self.keywords = keywords
        self.hostTypoMemory = hostTypoMemory
        self.intranetHosts = intranetHosts
    }

    /// The URL typed `input` loads after its top-level-domain typo is fixed
    /// (`example.con` -> `https://example.com`), and the host as typed; nil
    /// when there is no typo, or this host was fixed before (the user typed
    /// it again on purpose). Only for text the user typed.
    public func typoFixedURL(for input: String) -> (url: URL, typedHost: String)? {
        guard let fix = HostTypoFixup.fix(input), hostTypoMemory.allowsFix(of: fix.typedHost),
              let url = urlResolver.url(for: fix.text) else { return nil }
        return (url, fix.typedHost)
    }

    /// `typoFixedURL(for:)` for a commit: the fix is recorded, so the same
    /// typed host loads as typed next time.
    public func commitTypoFix(for input: String) -> URL? {
        guard let fixed = typoFixedURL(for: input) else { return nil }
        hostTypoMemory.recordFix(of: fixed.typedHost)
        return fixed.url
    }

    /// Where `input` goes: a URL, else a search. A leading `?` forces a
    /// search for the rest (Chromium `AutocompleteInput`: "?" is the
    /// forced-query prefix).
    public func destination(for input: String) -> OmniboxDestination? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("?") {
            let query = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty, let url = searchEngine.searchURL(for: query) else { return nil }
            return .search(query: query, url: url)
        }
        if let url = urlResolver.url(for: input) {
            return .url(url)
        }
        if let host = intranetHost(trimmed) {
            return .url(host)
        }
        let query = trimmed
        guard let url = searchEngine.searchURL(for: query) else { return nil }
        return .search(query: query, url: url)
    }

    /// `http://word/` for a bare word the probe found on the intranet (`wiki`).
    private func intranetHost(_ text: String) -> URL? {
        guard let label = IntranetHostProbe.candidate(text), intranetHosts.isIntranetHost(label) else { return nil }
        return URL(string: "http://\(label)/")
    }

    /// The web search a typed intranet address also offers (Chrome lists
    /// "go/gday - Google Search" under `http://go/gday`): the address may
    /// be a word on a network without that host. Nil for any other input.
    public func intranetSearchAlternative(for input: String) -> (query: String, url: URL)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("?"), !trimmed.contains("://"), case .url(let url)? = destination(for: trimmed),
              url.scheme == "http", let host = url.host(), !host.contains("."), !host.contains(":"),
              !BrowserURLResolver.isLoopback(host), let search = searchEngine.searchURL(for: trimmed) else { return nil }
        return (trimmed, search)
    }
}
