import Foundation

/// Search engines as omnibar keywords (Chrome's tab to search): typing an
/// engine's keyword (`youtube.com`) and Tab or a space starts a search
/// with that engine; the chip says "Search YouTube" and Enter searches
/// there. Chrome adds a site's engine when the site offers OpenSearch; cmux
/// ships the built-in engines and the sites people search most.
nonisolated extension BrowserSearchEngine {
    static let youtube = BrowserSearchEngine(
        id: "youtube", name: "YouTube", queryTemplate: "https://www.youtube.com/results?search_query={searchTerms}"
    )
    static let wikipedia = BrowserSearchEngine(
        id: "wikipedia", name: "Wikipedia", queryTemplate: "https://en.wikipedia.org/w/index.php?search={searchTerms}"
    )
    static let github = BrowserSearchEngine(
        id: "github", name: "GitHub", queryTemplate: "https://github.com/search?q={searchTerms}"
    )

    /// Sites with a search engine besides the built-in engines.
    static let siteSearches: [BrowserSearchEngine] = [youtube, wikipedia, github]

    /// Keywords that differ from the search host without `www.`.
    private static let keywordOverrides = ["wikipedia": "wikipedia.org"]

    /// What the user types to search with this engine: its search host
    /// without `www.` (`google.com`, `search.brave.com`), nil when the
    /// template has no host.
    var keyword: String? {
        if let keyword = Self.keywordOverrides[id] { return keyword }
        let probe = queryTemplate.replacingOccurrences(of: Self.placeholder, with: "x")
        guard let host = URL(string: probe)?.host()?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The engine's site (Enter with no text in its keyword session).
    var siteURL: URL? {
        var components = URLComponents(string: queryTemplate.replacingOccurrences(of: Self.placeholder, with: "x"))
        components?.path = "/"
        components?.query = nil
        components?.fragment = nil
        return components?.url
    }
}

nonisolated extension OmnibarKeyword {
    /// A search engine's keyword: Enter searches with `engine`.
    init(searchEngine engine: BrowserSearchEngine) {
        self.init(extensionID: "", keyword: engine.keyword ?? "", name: engine.name)
        searchEngine = engine
    }

    /// The keywords of `engine` (the default, first), the built-in engines
    /// and the site searches, one per keyword.
    static func searchEngines(default engine: BrowserSearchEngine) -> [OmnibarKeyword] {
        var seen = Set<String>()
        return ([engine] + BrowserSearchEngine.builtIn + BrowserSearchEngine.siteSearches).compactMap { engine in
            guard let keyword = engine.keyword, seen.insert(keyword).inserted else { return nil }
            return OmnibarKeyword(searchEngine: engine)
        }
    }
}
