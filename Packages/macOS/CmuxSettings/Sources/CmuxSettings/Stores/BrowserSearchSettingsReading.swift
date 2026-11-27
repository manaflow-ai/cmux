import Foundation

/// Read access to the browser search settings.
///
/// Consumers depend on this seam instead of the concrete
/// ``BrowserSearchSettingsStore`` so tests can inject an isolated
/// `UserDefaults` suite.
public protocol BrowserSearchSettingsReading: Sendable {
    /// The currently selected browser search engine.
    var currentSearchEngine: BrowserSearchEngine { get }

    /// The resolved browser search configuration.
    var currentConfiguration: BrowserSearchConfiguration { get }

    /// Whether address-bar search suggestions are enabled.
    var currentSearchSuggestionsEnabled: Bool { get }

    /// Resolves a browser search configuration from raw stored values.
    ///
    /// - Parameters:
    ///   - engineRaw: Stored raw search engine value.
    ///   - customName: Stored custom engine display name.
    ///   - customURLTemplate: Stored custom search URL template.
    /// - Returns: A configuration with legacy fallbacks applied.
    func configuration(
        engineRaw: String?,
        customName: String?,
        customURLTemplate: String?
    ) -> BrowserSearchConfiguration

    /// Normalizes a custom search engine name.
    ///
    /// - Parameter raw: The stored or entered name.
    /// - Returns: The trimmed name, or `nil` when it is empty.
    func normalizedCustomSearchEngineName(_ raw: String) -> String?

    /// Validates whether a custom search URL template can render a search URL.
    ///
    /// - Parameter raw: The stored or entered template.
    /// - Returns: `true` when the template can produce an allowed search URL.
    func isValidSearchURLTemplate(_ raw: String) -> Bool

    /// Renders a search URL from a template and raw query.
    ///
    /// - Parameters:
    ///   - rawTemplate: The URL template, optionally containing `{query}` or `%s`.
    ///   - rawQuery: The raw search query.
    /// - Returns: An allowed `http` or `https` URL, or `nil`.
    func searchURL(fromTemplate rawTemplate: String, query rawQuery: String) -> URL?
}
