import Foundation

/// Default search engine the cmux browser uses for address-bar queries.
public enum BrowserSearchEngine: String, CaseIterable, Identifiable, Sendable, SettingCodable {
    /// Google Search.
    case google

    /// DuckDuckGo search.
    case duckduckgo

    /// Microsoft Bing search.
    case bing

    /// Kagi search.
    case kagi

    /// Startpage search.
    case startpage

    /// Brave Search.
    case brave

    /// Perplexity search.
    case perplexity

    /// Exa search.
    case exa

    /// Yahoo Search.
    case yahoo

    /// Ecosia search.
    case ecosia

    /// Qwant search.
    case qwant

    /// Mojeek search.
    case mojeek

    /// Wikipedia search.
    case wikipedia

    /// GitHub search.
    case github

    /// Baidu search.
    case baidu

    /// Yandex search.
    case yandex

    /// User-provided search engine details.
    case custom

    /// Stable identifier matching the stored raw value.
    public var id: String { rawValue }

    /// Localized display name shown in browser and settings UI.
    public var displayName: String {
        switch self {
        case .google:
            return String(localized: "settings.browser.searchEngine.google", defaultValue: "Google")
        case .duckduckgo:
            return String(localized: "settings.browser.searchEngine.duckduckgo", defaultValue: "DuckDuckGo")
        case .bing:
            return String(localized: "settings.browser.searchEngine.bing", defaultValue: "Bing")
        case .kagi:
            return String(localized: "settings.browser.searchEngine.kagi", defaultValue: "Kagi")
        case .startpage:
            return String(localized: "settings.browser.searchEngine.startpage", defaultValue: "Startpage")
        case .brave:
            return String(localized: "settings.browser.searchEngine.brave", defaultValue: "Brave Search")
        case .perplexity:
            return String(localized: "settings.browser.searchEngine.perplexity", defaultValue: "Perplexity")
        case .exa:
            return String(localized: "settings.browser.searchEngine.exa", defaultValue: "Exa")
        case .yahoo:
            return String(localized: "settings.browser.searchEngine.yahoo", defaultValue: "Yahoo")
        case .ecosia:
            return String(localized: "settings.browser.searchEngine.ecosia", defaultValue: "Ecosia")
        case .qwant:
            return String(localized: "settings.browser.searchEngine.qwant", defaultValue: "Qwant")
        case .mojeek:
            return String(localized: "settings.browser.searchEngine.mojeek", defaultValue: "Mojeek")
        case .wikipedia:
            return String(localized: "settings.browser.searchEngine.wikipedia", defaultValue: "Wikipedia")
        case .github:
            return String(localized: "settings.browser.searchEngine.github", defaultValue: "GitHub")
        case .baidu:
            return String(localized: "settings.browser.searchEngine.baidu", defaultValue: "Baidu")
        case .yandex:
            return String(localized: "settings.browser.searchEngine.yandex", defaultValue: "Yandex")
        case .custom:
            return String(localized: "settings.browser.searchEngine.custom", defaultValue: "Custom")
        }
    }

    /// URL template used to render searches for built-in engines.
    public var searchURLTemplate: String? {
        switch self {
        case .google:
            return "https://www.google.com/search?q={query}"
        case .duckduckgo:
            return "https://duckduckgo.com/?q={query}"
        case .bing:
            return "https://www.bing.com/search?q={query}"
        case .kagi:
            return "https://kagi.com/search?q={query}"
        case .startpage:
            return "https://www.startpage.com/do/dsearch?q={query}"
        case .brave:
            return "https://search.brave.com/search?q={query}"
        case .perplexity:
            return "https://www.perplexity.ai/search?q={query}"
        case .exa:
            return "https://exa.ai/search?q={query}"
        case .yahoo:
            return "https://search.yahoo.com/search?p={query}"
        case .ecosia:
            return "https://www.ecosia.org/search?q={query}"
        case .qwant:
            return "https://www.qwant.com/?q={query}"
        case .mojeek:
            return "https://www.mojeek.com/search?q={query}"
        case .wikipedia:
            return "https://en.wikipedia.org/w/index.php?search={query}"
        case .github:
            return "https://github.com/search?q={query}"
        case .baidu:
            return "https://www.baidu.com/s?wd={query}"
        case .yandex:
            return "https://yandex.com/search/?text={query}"
        case .custom:
            return nil
        }
    }

    /// Whether the engine can be queried for remote search suggestions.
    public var supportsRemoteSuggestions: Bool {
        switch self {
        case .google, .duckduckgo, .bing, .kagi, .startpage:
            return true
        case .brave, .perplexity, .exa, .yahoo, .ecosia, .qwant, .mojeek, .wikipedia, .github, .baidu, .yandex, .custom:
            return false
        }
    }

    /// Renders a search URL for `query` using the engine's built-in template.
    ///
    /// - Parameter query: The raw search query.
    /// - Returns: An allowed `http` or `https` URL, or `nil` when the engine
    ///   has no built-in template.
    public func searchURL(query: String) -> URL? {
        guard let template = searchURLTemplate else { return nil }
        return BrowserSearchSettingsStore().searchURL(fromTemplate: template, query: query)
    }
}
