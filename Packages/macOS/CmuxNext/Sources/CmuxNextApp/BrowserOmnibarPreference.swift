import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextSettings
import CmuxNextWakeups
import Observation
import os

extension OmniboxConfiguration {
    /// The configuration, and whether the chosen custom engine is unusable
    /// (no search address with `%s` or `{searchTerms}`). Then the address
    /// bar searches with Google, never with the broken address; the caller
    /// logs a fault and Settings shows the row's message.
    static func resolve(_ setting: BrowserOmnibarSetting) -> (configuration: OmniboxConfiguration, invalidCustomEngine: Bool) {
        var engine = BrowserSearchEngine.builtIn.first { $0.id == setting.searchEngine } ?? .google
        var invalid = false
        if setting.searchEngine == "custom" {
            let custom = BrowserSearchEngine.custom(search: setting.customSearch, suggest: setting.customSuggest)
            invalid = setting.customSearch.isEmpty || custom.searchURL(for: "cmux") == nil
            engine = invalid ? .google : custom
        }
        let configuration = OmniboxConfiguration(searchEngine: engine, remoteSuggestions: setting.remoteSuggestions,
                                                 inlineAutocomplete: setting.inlineAutocomplete, maxRows: setting.maxRows,
                                                 calculator: setting.calculator, showFullURLs: setting.showFullURLs)
        return (configuration, invalid)
    }
}

/// Every suggestion engine (each browser profile's and incognito's) follows
/// every loaded snapshot's address bar keys; engines made later start from
/// the newest (`TabContentCache.omniboxConfiguration`).
@MainActor
enum BrowserOmnibarPreference {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "omnibar")

    /// Starts following; the caller keeps the returned followers for as long as the engines follow (the app's life).
    static func follow(_ settings: SettingsController, cache: TabContentCache, on mainWork: MainWorkScheduler) -> [AnyObject] {
        // The password keys follow from here too: AppDelegate, which starts the followers, is at its line budget.
        let passwords = BrowserPasswordsPreference.follow(settings, chromium: cache.chromium, on: mainWork)
        // Chromium's own search (chrome://settings/search, its menu rows) uses the same engine: the newest
        // one when its engine is built, then each change. Following builds no engine.
        cache.chromium.whenBuilt { [weak cache] cef in
            if let cache { cef.setDefaultSearch(cache.omniboxConfiguration.searchEngine) }
        }
        var reported: BrowserOmnibarSetting?
        // `visible`: the omnibar's glass and its suggestions show the change.
        let omnibar = ServiceObservation(.visible, owner: "BrowserOmnibarPreference", on: mainWork) {
            settings.snapshot.browserOmnibar
        } apply: { [weak cache] setting in
            guard let cache else { return }
            let resolved = OmniboxConfiguration.resolve(setting)
            if resolved.invalidCustomEngine, reported != setting {
                // One fault per distinct setting; the address itself is not logged (privacy).
                logger.fault("browser.searchEngine is custom without a usable browser.customSearchEngine.search; searching with Google")
            }
            reported = resolved.invalidCustomEngine ? setting : nil
            OmnibarGlassAppearance.shared.apply(glass: setting.glass, tint: setting.glassTint, tintStrength: setting.glassTintStrength,
                                                cornerRadius: setting.cornerRadius, shadow: setting.shadow, backgroundOpacity: setting.backgroundOpacity)
            cache.omniboxConfiguration = resolved.configuration
            for engine in cache.suggestionEngines { engine.apply(cache.omniboxConfiguration) }
            cache.chromium.built?.setDefaultSearch(resolved.configuration.searchEngine)
        }
        return [passwords, omnibar]
    }
}
