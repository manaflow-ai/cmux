public import CmuxNextSettings
public import CmuxNextCompat
import CmuxNextDesign
import CmuxNextWakeups
public import Foundation

/// Applies `app.language` (Leo, 2026-11-16: "we gotta add settings for changing languages"). The
/// language logic is cmux-config's and the pages'; this only hands the chosen code (nil: System) to
/// its readers:
/// - cmux's own string bundles (``AppLanguage``), so native text switches at once: every view
///   that looked up a cmux string in an observation scope runs again;
/// - every first-party page (``PageWebView/applyLanguage()``), which switches at once;
/// - the app's own `AppleLanguages`, in its defaults domain and never the global one: the menu bar
///   and the action catalog (command titles), made once per launch, take it at the next launch
///   (Settings' relaunch row, `AppLanguageRelaunchRoute`).
@MainActor
public final class AppLanguageApplier {
    static let languagesKey = "AppleLanguages"
    /// The code this applier last wrote. System removes `AppleLanguages` only while it still holds
    /// that write, so a per-app language picked in macOS System Settings stays the person's.
    static let appliedKey = "cmuxNext.appLanguage.applied"
    /// The app's own `AppleLanguages` from before cmux's first write (a language picked in macOS
    /// System Settings), which System puts back. It is kept in defaults, so it outlives relaunches.
    static let previousKey = "cmuxNext.appLanguage.previous"

    private let defaults: UserDefaults
    /// The name of `defaults`' own domain, read without the global domain's fallback.
    private let domain: String?
    private let pages: @MainActor (String?) -> Void
    private let refreshPages: @MainActor (String?) -> Void
    /// cmux's own string bundles' language (the app's one ``AppLanguage``).
    let language: AppLanguage
    private var observation: Task<Void, Never>?

    /// `defaults` is the app's own domain (`.standard`, named `domain`); `pages` hands a code to the
    /// pages (tests record it); `language` switches cmux's native text.
    public init(defaults: UserDefaults, domain: String? = Bundle.main.bundleIdentifier,
                pages: (@MainActor (String?) -> Void)? = nil, language: AppLanguage = AppLanguage()) {
        self.defaults = defaults
        self.domain = domain
        self.pages = pages ?? Self.pushToPages
        if let pages { self.refreshPages = pages } else { self.refreshPages = Self.refreshToPages }
        self.language = language
    }

    /// Applies every loaded snapshot's `app.language` (Observation, once per change). The
    /// observation holds this applier: the app makes one when its settings controller is set and
    /// keeps no other reference.
    public func follow(_ settings: SettingsController) {
        observation?.cancel()
        language.adoptResourceBundles()
        // A pack activation changes the files behind an already loaded document even when the
        // selected language code is unchanged. Re-apply the page hook so its locale script is
        // fetched from the newly active pack instead of leaving the page on its English table.
        Bundle.observeLanguagePacks { [weak self] in
            MainDelivery().run { [weak self] in
                guard let self else { return }
                self.refreshPages(self.language.code)
            }
        }
        // task-owner: lives as long as the app's settings controller (app lifetime).
        observation = Task { [self] in
            await settings.waitForLoad(atLeast: 1)
            for await code in ObservationStream({ settings.snapshot.appLanguage }) { apply(code) }
        }
    }

    func apply(_ code: String?) {
        writeDefaults(code)
        language.set(code)
        pages(code)
    }

    /// `[code]` as the app's `AppleLanguages`; System takes back cmux's own write and puts back the
    /// per-app language it replaced, if any.
    func writeDefaults(_ code: String?) {
        let applied = defaults.string(forKey: Self.appliedKey)
        if let code {
            if applied == nil {
                if let own = ownLanguages { defaults.set(own, forKey: Self.previousKey) } else { defaults.removeObject(forKey: Self.previousKey) }
            }
            defaults.set([code], forKey: Self.languagesKey)
            defaults.set(code, forKey: Self.appliedKey)
            return
        }
        guard let applied else { return }
        // Changed in macOS System Settings since cmux's write: that choice stays.
        if ownLanguages == [applied] {
            if let previous = defaults.stringArray(forKey: Self.previousKey) { defaults.set(previous, forKey: Self.languagesKey) } else { defaults.removeObject(forKey: Self.languagesKey) }
        }
        defaults.removeObject(forKey: Self.appliedKey)
        defaults.removeObject(forKey: Self.previousKey)
    }

    /// The app domain's own `AppleLanguages` (`stringArray(forKey:)` falls back to the global one).
    private var ownLanguages: [String]? {
        guard let domain else { return defaults.stringArray(forKey: Self.languagesKey) }
        return defaults.persistentDomain(forName: domain)?[Self.languagesKey] as? [String]
    }

    /// The code for every later document, and now to every live one.
    private static func pushToPages(_ code: String?) {
        DesignSettings.shared.appLanguage = code
        for page in PageRegistry.pages() { page.applyLanguage() }
    }

    /// Replays the current code after a pack becomes active. The page must reload its locale
    /// script because the same URL now resolves to the downloaded pack through the scheme handler.
    private static func refreshToPages(_ code: String?) {
        DesignSettings.shared.appLanguage = code
        for page in PageRegistry.pages() { page.applyLanguage(refresh: true) }
    }
}
