import CmuxNextBrowser
import CmuxNextSettings
import Observation
import os

extension OmniboxConfiguration {
    /// Pure: cmux.json's address bar keys as the browser module's value.
    init(_ setting: BrowserOmnibarSetting) {
        self = Self.resolve(setting).configuration
    }

    /// The configuration, and whether the chosen custom engine is unusable
    /// (no search address with `%s` or `{searchTerms}`). Then the address
    /// bar searches with Google, never with the broken address; the caller
    /// logs a fault and Settings shows the row's message.
    static func resolve(_ setting: BrowserOmnibarSetting) -> (configuration: OmniboxConfiguration, invalidCustomEngine: Bool) {
        var engine = BrowserSearchEngine.builtIn.first { $0.id == setting.searchEngine } ?? .google
        var invalid = false
        if setting.searchEngine == "custom" {
            let custom = BrowserSearchEngine.custom(search: setting.customSearch, suggest: setting.customSuggest)
            // Red: the fallback is silent.
            engine = setting.customSearch.isEmpty || custom.searchURL(for: "cmux") == nil ? .google : custom
        }
        let configuration = OmniboxConfiguration(searchEngine: engine, remoteSuggestions: setting.remoteSuggestions,
                                                 inlineAutocomplete: setting.inlineAutocomplete, maxRows: setting.maxRows,
                                                 calculator: setting.calculator)
        return (configuration, invalid)
    }
}

/// Every suggestion engine (each browser profile's and incognito's) follows
/// every loaded snapshot's address bar keys; engines made later start from
/// the newest (`TabContentCache.omniboxConfiguration`).
@MainActor
enum BrowserOmnibarPreference {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "omnibar")

    static func follow(_ settings: SettingsController, cache: TabContentCache) {
        // task-owner: lives as long as the app's settings and cache; both weak.
        Task { [weak settings, weak cache] in
            guard let settings else { return }
            var reported: BrowserOmnibarSetting?
            for await setting in Observations({ settings.snapshot.browserOmnibar }) {
                guard let cache else { return }
                let resolved = OmniboxConfiguration.resolve(setting)
                if resolved.invalidCustomEngine, reported != setting {
                    // One fault per distinct setting; the address itself is not logged (privacy).
                    logger.fault("browser.searchEngine is custom without a usable browser.customSearchEngine.search; searching with Google")
                }
                reported = resolved.invalidCustomEngine ? setting : nil
                cache.omniboxConfiguration = resolved.configuration
                for engine in cache.suggestionEngines { engine.apply(cache.omniboxConfiguration) }
            }
        }
    }
}
