public import Foundation

/// A web search engine the address bar falls back to.
public nonisolated struct BrowserSearchEngine: Hashable, Sendable, Codable, Identifiable {
    public static let placeholder = "{searchTerms}"

    public var id: String
    public var name: String
    /// URL with `{searchTerms}` where the encoded query goes.
    public var queryTemplate: String

    public init(id: String, name: String, queryTemplate: String) {
        self.id = id
        self.name = name
        self.queryTemplate = queryTemplate
    }

    /// The search results URL for `query`, or nil for an empty query or a
    /// malformed template.
    public func searchURL(for query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              queryTemplate.contains(Self.placeholder),
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed) else {
            return nil
        }
        return URL(string: queryTemplate.replacingOccurrences(of: Self.placeholder, with: encoded))
    }

    /// RFC 3986 unreserved characters only, so `&`, `+`, `#`, `=` in the query
    /// never change the URL structure.
    private static let queryValueAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
    )

    public static let google = BrowserSearchEngine(
        id: "google", name: "Google", queryTemplate: "https://www.google.com/search?q={searchTerms}"
    )
    public static let duckDuckGo = BrowserSearchEngine(
        id: "duckduckgo", name: "DuckDuckGo", queryTemplate: "https://duckduckgo.com/?q={searchTerms}"
    )
    public static let bing = BrowserSearchEngine(
        id: "bing", name: "Bing", queryTemplate: "https://www.bing.com/search?q={searchTerms}"
    )
    public static let kagi = BrowserSearchEngine(
        id: "kagi", name: "Kagi", queryTemplate: "https://kagi.com/search?q={searchTerms}"
    )

    public static let builtIn: [BrowserSearchEngine] = [google, duckDuckGo, bing, kagi]
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
