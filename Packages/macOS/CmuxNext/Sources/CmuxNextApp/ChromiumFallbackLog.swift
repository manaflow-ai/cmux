import CmuxNextBrowser
import CmuxNextDaemon

/// Every time a tab that should have been Chromium opened in WebKit
/// instead (Chromium is the default engine, or the tab's record names it),
/// with the typed reason for `debug.cef`. The first fallback page shown in
/// this process gets one subtle notice (`BrowserChromeView.showNotice`); after
/// that fallbacks are only counted, so the notice never repeats.
@MainActor
final class ChromiumFallbackLog {
    enum Source: String {
        /// A new tab with no explicit engine (default Chromium).
        case newTab
        /// A tab whose record names Chromium (restored, reopened, created
        /// elsewhere) while CEF is missing or failed to start.
        case recordedTab
    }

    private(set) var lastReason: CEFUnavailableReason?
    private(set) var lastSource: Source?
    private(set) var count = 0
    /// True once the notice was handed to a tab.
    private(set) var notified = false
    /// Fallback tabs whose page was not created yet; the first one shown
    /// takes the notice. Emptied once notified.
    private var candidates: [SurfaceID: CEFUnavailableReason] = [:]

    /// Records a fallback for the tab on `surface` (nil when unknown yet).
    func record(_ reason: CEFUnavailableReason, source: Source, surface: SurfaceID?) {
        lastReason = reason
        lastSource = source
        count += 1
        guard !notified, let surface else { return }
        candidates[surface] = reason
    }

    /// The notice text when `surface` is a fallback tab and no notice was
    /// shown yet in this process (once).
    func takeNotice(for surface: SurfaceID) -> String? {
        guard !notified, let reason = candidates[surface] else { return nil }
        notified = true
        candidates = [:]
        return Self.notice(for: reason)
    }

    static func notice(for reason: CEFUnavailableReason) -> String {
        switch reason {
        case .notBundled: BrowserEngineStrings.fallbackNotBundled
        case .startFailed, .shutDown: BrowserEngineStrings.fallbackStartFailed
        }
    }
}

/// Engine-choice strings (default engine actions, the fallback notice).
enum BrowserEngineStrings {
    static var fallbackNotBundled: String {
        String(localized: "browser.engine.fallback.notBundled", defaultValue: "Chromium isn’t in this build, so this tab uses WebKit.", bundle: .module)
    }
    static var fallbackStartFailed: String {
        String(localized: "browser.engine.fallback.startFailed", defaultValue: "Chromium couldn’t start, so this tab uses WebKit.", bundle: .module)
    }
}
