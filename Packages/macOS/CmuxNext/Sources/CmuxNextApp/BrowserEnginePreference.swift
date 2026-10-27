import CmuxNextBrowserTabs
import CmuxNextCompat
import CmuxNextSettings
import CmuxNextWakeups
import Observation

/// The live `browser.defaultEngine`: follows cmux.json, and the default
/// engine actions set it at once before their file write comes back through
/// the watcher (like density). Observable so the Chromium warm-start policy
/// can follow it.
@MainActor
@Observable
final class BrowserEnginePreference {
    var defaultEngine: BrowserDefaultEngine = .fallback
    /// The live `browser.siteEngines`: sites that open in a set engine.
    var siteEngines: BrowserSiteEngines = .fallback
    @ObservationIgnored private var engineWatch: ServiceObservation<BrowserDefaultEngine>?
    @ObservationIgnored private var siteWatch: ServiceObservation<BrowserSiteEngines>?

    /// Applies every loaded snapshot's value, the current one now. `visible`: the engine is what the
    /// tabs this launch restores and opens show; a person's change flushes before its frame.
    func follow(_ settings: SettingsController, on mainWork: MainWorkScheduler) {
        engineWatch = ServiceObservation(.visible, owner: "BrowserEnginePreference.defaultEngine", on: mainWork) {
            settings.snapshot.browserDefaultEngine
        } apply: { [weak self] engine in
            if let self, self.defaultEngine != engine { self.defaultEngine = engine }
        }
        siteWatch = ServiceObservation(.visible, owner: "BrowserEnginePreference.siteEngines", on: mainWork) {
            settings.snapshot.browserSiteEngines
        } apply: { [weak self] rules in
            if let self, self.siteEngines != rules { self.siteEngines = rules }
        }
    }
}

extension AppServices {
    /// What a new browser tab opens when nothing asked for a page:
    /// `browser.newTabPage`, else the engine's New Tab page (Chromium's
    /// chrome://newtab/, where new-tab extensions show; WebKit's blank page).
    func newTabAddress(for choice: BrowserEngineChoice) -> String {
        settings?.snapshot.browserNewTabPage?.absoluteString ?? choice.newTabURL
    }
}
