import Foundation
import Combine
import WebKit
import AppKit
import Bonsplit
import Network
import CFNetwork
import SQLite3
import CryptoKit
import Darwin
#if canImport(CommonCrypto)
import CommonCrypto
#endif
#if canImport(Security)
import Security
#endif


// MARK: - Browser search engine settings
enum BrowserSearchEngine: String, CaseIterable, Identifiable {
    case google
    case duckduckgo
    case bing
    case kagi
    case startpage
    case brave
    case perplexity
    case exa
    case yahoo
    case ecosia
    case qwant
    case mojeek
    case wikipedia
    case github
    case baidu
    case yandex
    case custom

    var id: String { rawValue }

    var displayName: String {
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

    var searchURLTemplate: String? {
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

    var supportsRemoteSuggestions: Bool {
        switch self {
        case .google, .duckduckgo, .bing, .kagi, .startpage:
            return true
        case .brave, .perplexity, .exa, .yahoo, .ecosia, .qwant, .mojeek, .wikipedia, .github, .baidu, .yandex, .custom:
            return false
        }
    }

    func searchURL(query: String) -> URL? {
        guard let template = searchURLTemplate else { return nil }
        return BrowserSearchSettings.searchURL(fromTemplate: template, query: query)
    }
}

struct BrowserSearchConfiguration: Equatable {
    let engine: BrowserSearchEngine
    let customName: String
    let customURLTemplate: String

    var displayName: String {
        guard engine == .custom else { return engine.displayName }
        return BrowserSearchSettings.normalizedCustomSearchEngineName(customName)
            ?? engine.displayName
    }

    var remoteSuggestionsEngine: BrowserSearchEngine? {
        guard engine.supportsRemoteSuggestions else { return nil }
        return engine
    }

    func searchURL(query: String) -> URL? {
        if engine == .custom {
            return BrowserSearchSettings.searchURL(fromTemplate: customURLTemplate, query: query)
        }
        return engine.searchURL(query: query)
    }
}

enum BrowserSearchSettings {
    static let searchEngineKey = "browserSearchEngine"
    static let customSearchEngineNameKey = "browserCustomSearchEngineName"
    static let customSearchEngineURLTemplateKey = "browserCustomSearchEngineURLTemplate"
    static let searchSuggestionsEnabledKey = "browserSearchSuggestionsEnabled"
    static let defaultSearchEngine: BrowserSearchEngine = .google
    static let defaultCustomSearchEngineName = ""
    static let defaultCustomSearchEngineURLTemplate = "https://www.google.com/search?q={query}"
    static let defaultSearchSuggestionsEnabled: Bool = true

    static func currentSearchEngine(defaults: UserDefaults = .standard) -> BrowserSearchEngine {
        guard let raw = defaults.string(forKey: searchEngineKey),
              let engine = BrowserSearchEngine(rawValue: raw) else {
            return defaultSearchEngine
        }
        return engine
    }

    static func currentConfiguration(defaults: UserDefaults = .standard) -> BrowserSearchConfiguration {
        configuration(
            engineRaw: defaults.string(forKey: searchEngineKey),
            customName: defaults.string(forKey: customSearchEngineNameKey),
            customURLTemplate: defaults.string(forKey: customSearchEngineURLTemplateKey)
        )
    }

    static func configuration(
        engineRaw: String?,
        customName: String?,
        customURLTemplate: String?
    ) -> BrowserSearchConfiguration {
        let engine = engineRaw.flatMap(BrowserSearchEngine.init(rawValue:)) ?? defaultSearchEngine
        let resolvedCustomURLTemplate = customURLTemplate
            .flatMap { isValidSearchURLTemplate($0) ? $0 : nil }
            ?? defaultCustomSearchEngineURLTemplate
        return BrowserSearchConfiguration(
            engine: engine,
            customName: customName ?? defaultCustomSearchEngineName,
            customURLTemplate: resolvedCustomURLTemplate
        )
    }

    static func normalizedCustomSearchEngineName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func isValidSearchURLTemplate(_ raw: String) -> Bool {
        searchURL(fromTemplate: raw, query: "cmux search") != nil
    }

    static func searchURL(fromTemplate rawTemplate: String, query rawQuery: String) -> URL? {
        let template = rawTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty, !query.isEmpty else { return nil }

        if template.contains("{query}") || template.contains("%s") {
            let encodedQuery = percentEncodedSearchQuery(query)
            let rendered = template
                .replacingOccurrences(of: "{query}", with: encodedQuery)
                .replacingOccurrences(of: "%s", with: encodedQuery)
            guard let url = URL(string: rendered), isAllowedSearchURL(url) else { return nil }
            return url
        }

        guard var components = URLComponents(string: template) else { return nil }
        let encodedQuery = percentEncodedSearchQuery(query)
        let existingQuery = components.percentEncodedQuery ?? ""
        components.percentEncodedQuery = existingQuery.isEmpty
            ? "q=\(encodedQuery)"
            : "\(existingQuery)&q=\(encodedQuery)"
        guard let url = components.url, isAllowedSearchURL(url) else { return nil }
        return url
    }

    private static func percentEncodedSearchQuery(_ query: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
    }

    private static func isAllowedSearchURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else {
            return false
        }
        return true
    }

    static func currentSearchSuggestionsEnabled(defaults: UserDefaults = .standard) -> Bool {
        // Mirror @AppStorage behavior: bool(forKey:) returns false if key doesn't exist.
        // Default to enabled unless user explicitly set a value.
        if defaults.object(forKey: searchSuggestionsEnabledKey) == nil {
            return defaultSearchSuggestionsEnabled
        }
        return defaults.bool(forKey: searchSuggestionsEnabledKey)
    }
}

