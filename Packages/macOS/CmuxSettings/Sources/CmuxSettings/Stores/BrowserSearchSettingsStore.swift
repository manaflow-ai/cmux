import Foundation

/// Repository for browser search settings persisted in `UserDefaults`.
///
/// Isolation: a stateless `Sendable` struct, not an actor. Browser search
/// readers are synchronous call paths such as address-bar resolution and
/// settings-file import validation; the struct holds no mutable state, and
/// `UserDefaults` is documented thread-safe.
public struct BrowserSearchSettingsStore: BrowserSearchSettingsReading {
    /// Defaults key storing the selected search engine raw value.
    public static let searchEngineKey = "browserSearchEngine"

    /// Defaults key storing the custom search engine display name.
    public static let customSearchEngineNameKey = "browserCustomSearchEngineName"

    /// Defaults key storing the custom search URL template.
    public static let customSearchEngineURLTemplateKey = "browserCustomSearchEngineURLTemplate"

    /// Defaults key storing whether search suggestions are enabled.
    public static let searchSuggestionsEnabledKey = "browserSearchSuggestionsEnabled"

    /// Legacy default selected search engine.
    public static let defaultSearchEngine: BrowserSearchEngine = .google

    /// Legacy default custom search engine display name.
    public static let defaultCustomSearchEngineName = ""

    /// Legacy default custom search URL template.
    public static let defaultCustomSearchEngineURLTemplate = "https://www.google.com/search?q={query}"

    /// Legacy default search suggestions toggle value.
    public static let defaultSearchSuggestionsEnabled: Bool = true

    // UserDefaults is documented thread-safe and the reference is immutable.
    private nonisolated(unsafe) let defaults: UserDefaults

    /// Creates a store reading the given defaults suite.
    ///
    /// - Parameter defaults: The defaults suite holding browser search settings.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var currentSearchEngine: BrowserSearchEngine {
        guard let raw = defaults.string(forKey: Self.searchEngineKey),
              let engine = BrowserSearchEngine(rawValue: raw) else {
            return Self.defaultSearchEngine
        }
        return engine
    }

    public var currentConfiguration: BrowserSearchConfiguration {
        configuration(
            engineRaw: defaults.string(forKey: Self.searchEngineKey),
            customName: defaults.string(forKey: Self.customSearchEngineNameKey),
            customURLTemplate: defaults.string(forKey: Self.customSearchEngineURLTemplateKey)
        )
    }

    public var currentSearchSuggestionsEnabled: Bool {
        // Mirror @AppStorage behavior: bool(forKey:) returns false if key doesn't exist.
        // Default to enabled unless user explicitly set a value.
        if defaults.object(forKey: Self.searchSuggestionsEnabledKey) == nil {
            return Self.defaultSearchSuggestionsEnabled
        }
        return defaults.bool(forKey: Self.searchSuggestionsEnabledKey)
    }

    public func configuration(
        engineRaw: String?,
        customName: String?,
        customURLTemplate: String?
    ) -> BrowserSearchConfiguration {
        let engine = engineRaw.flatMap(BrowserSearchEngine.init(rawValue:)) ?? Self.defaultSearchEngine
        let resolvedCustomURLTemplate = customURLTemplate
            .flatMap { isValidSearchURLTemplate($0) ? $0 : nil }
            ?? Self.defaultCustomSearchEngineURLTemplate
        return BrowserSearchConfiguration(
            engine: engine,
            customName: customName ?? Self.defaultCustomSearchEngineName,
            customURLTemplate: resolvedCustomURLTemplate
        )
    }

    public func normalizedCustomSearchEngineName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func isValidSearchURLTemplate(_ raw: String) -> Bool {
        searchURL(fromTemplate: raw, query: "cmux search") != nil
    }

    public func searchURL(fromTemplate rawTemplate: String, query rawQuery: String) -> URL? {
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

    private func percentEncodedSearchQuery(_ query: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
    }

    private func isAllowedSearchURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else {
            return false
        }
        return true
    }
}
