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

    public init(urlResolver: BrowserURLResolver = BrowserURLResolver(), searchEngine: BrowserSearchEngine = .google,
                keywords: [OmnibarKeyword] = []) {
        self.urlResolver = urlResolver
        self.searchEngine = searchEngine
        self.keywords = keywords
    }

    public func destination(for input: String) -> OmniboxDestination? {
        if let url = urlResolver.url(for: input) {
            return .url(url)
        }
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = searchEngine.searchURL(for: query) else { return nil }
        return .search(query: query, url: url)
    }
}
