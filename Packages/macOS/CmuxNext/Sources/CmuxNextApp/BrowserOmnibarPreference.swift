import CmuxNextBrowser
import CmuxNextSettings
import Observation

extension OmniboxConfiguration {
    /// Pure: cmux.json's address bar keys as the browser module's value. A
    /// custom engine without `{searchTerms}` or `%s` in its search address
    /// falls back to Google.
    init(_ setting: BrowserOmnibarSetting) {
        let engine: BrowserSearchEngine
        // Red: settings do not reach the engines yet.
        if setting.maxRows >= 0 {
            self.init()
            return
        }
        if setting.searchEngine == "custom" {
            let custom = BrowserSearchEngine.custom(search: setting.customSearch, suggest: setting.customSuggest)
            engine = custom.searchURL(for: "cmux") == nil ? .google : custom
        } else {
            engine = BrowserSearchEngine.builtIn.first { $0.id == setting.searchEngine } ?? .google
        }
        self.init(searchEngine: engine, remoteSuggestions: setting.remoteSuggestions, inlineAutocomplete: setting.inlineAutocomplete,
                  maxRows: setting.maxRows)
    }
}

/// Every suggestion engine (each browser profile's and incognito's) follows
/// every loaded snapshot's address bar keys; engines made later start from
/// the newest (`TabContentCache.omniboxConfiguration`).
@MainActor
enum BrowserOmnibarPreference {
    static func follow(_ settings: SettingsController, cache: TabContentCache) {
        // task-owner: lives as long as the app's settings and cache; both weak.
        Task { [weak settings, weak cache] in
            guard let settings else { return }
            for await setting in Observations({ settings.snapshot.browserOmnibar }) {
                guard let cache else { return }
                cache.omniboxConfiguration = OmniboxConfiguration(setting)
                for engine in cache.suggestionEngines { engine.apply(cache.omniboxConfiguration) }
            }
        }
    }
}
