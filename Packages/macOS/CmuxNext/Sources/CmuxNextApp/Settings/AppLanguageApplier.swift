import AppKit
import CmuxNextCompat
import CmuxNextPages
import CmuxNextSettings
import CmuxNextUpdater
import Foundation

/// Applies `app.language` (Leo, 2026-11-16: "we gotta add settings for changing languages"). The
/// language logic is cmux-config's and the pages'; this only hands the chosen code (nil: System) to
/// the two readers:
/// - the app's own `AppleLanguages`, in its defaults domain and never the global one: the menus,
///   `Bundle` and every `String(localized:)` read it at the next launch, so native text switches
///   after a relaunch (Settings' relaunch row, ``AppLanguageRelaunchRoute``);
/// - every first-party page (``PageWebView/appLanguage``), which switches at once.
@MainActor
final class AppLanguageApplier {
    static let languagesKey = "AppleLanguages"
    /// The code this applier last wrote. System removes `AppleLanguages` only while it still holds
    /// that write, so a per-app language picked in macOS System Settings stays the person's.
    static let appliedKey = "cmuxNext.appLanguage.applied"

    private let defaults: UserDefaults
    private let pages: @MainActor (String?) -> Void
    private var observation: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, pages: @escaping @MainActor (String?) -> Void = { PageWebView.appLanguage = $0 }) {
        self.defaults = defaults
        self.pages = pages
    }

    /// Applies every loaded snapshot's `app.language` (Observation, once per change).
    func follow(_ settings: SettingsController) {
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
}

/// Settings > General > Language's relaunch row: `cmux.settings.language.relaunch {}` relaunches the
/// app through the update path's relaunch, keeping every session.
@MainActor
final class AppLanguageRelaunchRoute: PageProvider {
    static let prefix = "cmux.settings.language."
    private let relaunch: @MainActor () -> Void

    init(relaunch: @escaping @MainActor () -> Void) {
        self.relaunch = relaunch
    }

    /// The relaunch a rollback takes: the updater's relaunch hook records the quit as keeping every
    /// session, then a helper reopens this bundle once the process exits.
    convenience init(updater: UpdaterService) {
        self.init {
            updater.willRelaunch?()
            UpdateDropBack.relaunchAfterExit(Bundle.main.bundleURL) {
                updater.log.append("language: the relaunch helper did not start; quit cmux to use the new language")
            }
        }
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op == Self.prefix + "relaunch" else { throw PageError.unknownOp(op) }
        // A relaunch quits the app: only the person's own click in the page.
        guard context.userGesture else {
            throw PageError(code: PageNativeOp.userOnlyCode, message: "Relaunch needs the person's click")
        }
        relaunch()
        return .object([:])
    }
}
