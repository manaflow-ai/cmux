import Foundation

/// Resolved browser search settings used by the address bar.
public struct BrowserSearchConfiguration: Equatable, Sendable {
    /// The selected search engine.
    public let engine: BrowserSearchEngine

    /// The stored custom search engine display name.
    public let customName: String

    /// The stored custom search URL template.
    public let customURLTemplate: String

    /// Creates a resolved browser search configuration.
    ///
    /// - Parameters:
    ///   - engine: The selected search engine.
    ///   - customName: The custom search engine display name.
    ///   - customURLTemplate: The custom search URL template.
    public init(
        engine: BrowserSearchEngine,
        customName: String,
        customURLTemplate: String
    ) {
        self.engine = engine
        self.customName = customName
        self.customURLTemplate = customURLTemplate
    }

    /// Display name to show for the resolved engine.
    public var displayName: String {
        guard engine == .custom else { return engine.displayName }
        return BrowserSearchSettingsStore().normalizedCustomSearchEngineName(customName)
            ?? engine.displayName
    }

    /// Built-in engine to query for remote suggestions, if supported.
    public var remoteSuggestionsEngine: BrowserSearchEngine? {
        guard engine.supportsRemoteSuggestions else { return nil }
        return engine
    }

    /// Renders a search URL for the given query.
    ///
    /// - Parameter query: The raw search query.
    /// - Returns: An allowed `http` or `https` URL, or `nil` when the
    ///   configured template cannot produce one.
    public func searchURL(query: String) -> URL? {
        if engine == .custom {
            return BrowserSearchSettingsStore().searchURL(fromTemplate: customURLTemplate, query: query)
        }
        return engine.searchURL(query: query)
    }
}
