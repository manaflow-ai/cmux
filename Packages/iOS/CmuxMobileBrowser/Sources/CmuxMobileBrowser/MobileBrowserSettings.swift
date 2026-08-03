public import Foundation
public import Observation

/// User-tunable preferences for the phone-local browser.
@MainActor
@Observable
public final class MobileBrowserSettings {
    // UserDefaults is Apple-documented thread-safe; reads happen during init and writes happen on mutation.
    private nonisolated(unsafe) let defaults: UserDefaults
    private static let defaultSearchEngineKey = "cmux.mobile.browser.defaultSearchEngine"

    /// The search engine used for free-text address-bar input.
    public var defaultSearchEngine: MobileBrowserSearchEngine {
        didSet { defaults.set(defaultSearchEngine.rawValue, forKey: Self.defaultSearchEngineKey) }
    }

    /// The active search template for ``BrowserURLResolver``.
    public var searchTemplate: String {
        defaultSearchEngine.searchTemplate
    }

    /// Creates browser settings backed by injected defaults.
    /// - Parameter defaults: The store used for persistence. Tests pass a scoped suite.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.string(forKey: Self.defaultSearchEngineKey)
        self.defaultSearchEngine = raw.flatMap(MobileBrowserSearchEngine.init(rawValue:)) ?? .duckDuckGo
    }
}
