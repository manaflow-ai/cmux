public import Foundation

/// Reads Safari's search engine: the Mac's `NSPreferredWebServices`
/// (`NSWebServicesProviderWebSearch`, set by Safari's Search settings, a
/// display name and provider id such as "DuckDuckGo", "com.duckduckgo"),
/// mapped to the engine's address. Nil when Safari keeps its own default.
public struct SafariSearchEngineReader {
    public init() {}

    public func read() -> ImportedSearchEngine? {
        read(UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["NSPreferredWebServices"] as? [String: Any])
    }

    public func read(_ services: [String: Any]?) -> ImportedSearchEngine? {
        guard let search = services?["NSWebServicesProviderWebSearch"] as? [String: Any] else { return nil }
        return ImportedSearchEngine.wellKnown(named: [search["NSDefaultDisplayName"] as? String, search["NSProviderIdentifier"] as? String])
    }
}
