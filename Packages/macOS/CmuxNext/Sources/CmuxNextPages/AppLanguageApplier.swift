public import CmuxNextSettings
import CmuxNextCompat
import CmuxNextDesign
public import Foundation

/// Applies `app.language` (Leo, 2026-11-16: "we gotta add settings for changing languages"). The
/// language logic is cmux-config's and the pages'; this only hands the chosen code (nil: System) to
/// the two readers:
/// - the app's own `AppleLanguages`, in its defaults domain and never the global one: the menus,
///   `Bundle` and every `String(localized:)` read it at the next launch, so native text switches
///   after a relaunch (Settings' relaunch row, `AppLanguageRelaunchRoute`);
/// - every first-party page (``PageWebView/applyLanguage()``), which switches at once.
@MainActor
public final class AppLanguageApplier {
    static let languagesKey = "AppleLanguages"
    /// The code this applier last wrote. System removes `AppleLanguages` only while it still holds
    /// that write, so a per-app language picked in macOS System Settings stays the person's.
    static let appliedKey = "cmuxNext.appLanguage.applied"

    private let defaults: UserDefaults
    private let pages: @MainActor (String?) -> Void
    private var observation: Task<Void, Never>?

    /// `defaults` is the app's own domain (`.standard`); `pages` hands a code to the pages (tests
    /// record it).
    public init(defaults: UserDefaults, pages: (@MainActor (String?) -> Void)? = nil) {
        self.defaults = defaults
        self.pages = pages ?? Self.pushToPages
    }

    /// Applies every loaded snapshot's `app.language` (Observation, once per change).
    public func follow(_ settings: SettingsController) {
        observation?.cancel()
        // task-owner: lives as long as the app's settings; a new controller replaces it.
        observation = Task { [weak self] in
            await settings.waitForLoad(atLeast: 1)
            for await code in ObservationStream({ settings.snapshot.appLanguage }) {
                guard let self else { return }
                self.apply(code)
            }
        }
    }

    func apply(_ code: String?) {
        writeDefaults(code)
        pages(code)
    }

    /// `[code]` as the app's `AppleLanguages`; System removes cmux's own write.
    func writeDefaults(_ code: String?) {
        if let code {
            defaults.set([code], forKey: Self.languagesKey)
            defaults.set(code, forKey: Self.appliedKey)
            return
        }
        guard let applied = defaults.string(forKey: Self.appliedKey) else { return }
        if defaults.stringArray(forKey: Self.languagesKey) == [applied] { defaults.removeObject(forKey: Self.languagesKey) }
        defaults.removeObject(forKey: Self.appliedKey)
    }

    /// The code for every later document, and now to every live one.
    private static func pushToPages(_ code: String?) {
        guard DesignSettings.shared.appLanguage != code else { return }
        DesignSettings.shared.appLanguage = code
        for page in PageRegistry.pages() { page.applyLanguage() }
    }
}
