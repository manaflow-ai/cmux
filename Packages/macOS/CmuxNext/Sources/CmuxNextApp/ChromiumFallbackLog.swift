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
    /// Fallback tabs whose page was not created yet, by machine and surface
    /// (handles are per daemon); the first one shown takes the notice.
    /// Emptied once notified.
    private var candidates: [Candidate: CEFUnavailableReason] = [:]

    private struct Candidate: Hashable {
        let machine: String
        let surface: SurfaceID
    }

    /// Records a fallback for the tab on `machine`'s `surface` (nil when unknown yet).
    func record(_ reason: CEFUnavailableReason, source: Source, machine: String, surface: SurfaceID?) {
        lastReason = reason
        lastSource = source
        count += 1
        guard !notified, let surface else { return }
        candidates[Candidate(machine: machine, surface: surface)] = reason
    }

    /// The notice text when `machine`'s `surface` is a fallback tab and no
    /// notice was shown yet in this process (once).
    func takeNotice(machine: String, surface: SurfaceID) -> String? {
        guard !notified, let reason = candidates[Candidate(machine: machine, surface: surface)] else { return nil }
        notified = true
        candidates = [:]
        return Self.notice(for: reason)
    }

    static func notice(for reason: CEFUnavailableReason) -> String {
        switch reason {
        case .notBundled: BrowserEngineStrings.fallbackNotBundled
        case .downloading: BrowserEngineStrings.fallbackDownloading
        case .downloadFailed: BrowserEngineStrings.fallbackDownloadFailed
        case .startFailed, .shutDown, .openFileLimit: BrowserEngineStrings.fallbackStartFailed
        }
    }

    /// Why an explicit Chromium request is refused (localized). A download in
    /// progress or retrying gets its own text; the other reasons keep their
    /// failure detail.
    static func refusal(for reason: CEFUnavailableReason) -> String? {
        switch reason {
        case .downloading(let fraction): BrowserEngineStrings.downloading(fraction)
        case .downloadFailed: BrowserEngineStrings.downloadFailed
        case .notBundled, .startFailed, .shutDown, .openFileLimit: nil
        }
    }
}

/// Engine-choice strings (default engine actions, the fallback notice).
enum BrowserEngineStrings {
    static var fallbackNotBundled: String {
        String(localized: "browser.engine.fallback.notBundled", defaultValue: "Chromium isn’t in this build, so this tab uses WebKit.", bundle: .module)
    }
    static var fallbackDownloading: String {
        String(localized: "browser.engine.fallback.downloading",
               defaultValue: "Chromium is downloading, so this tab uses WebKit. New tabs use Chromium when it’s ready.", bundle: .module)
    }
    static var fallbackDownloadFailed: String {
        String(localized: "browser.engine.fallback.downloadFailed",
               defaultValue: "Chromium couldn’t download yet, so this tab uses WebKit. cmux will try again.", bundle: .module)
    }
    /// The refusal while the download runs; `fraction` (0...1) shows as a percentage, 0 before bytes flow.
    static func downloading(_ fraction: Double?) -> String {
        let percent = (fraction ?? 0).formatted(.percent.precision(.fractionLength(0)))
        return String(localized: "browser.engine.downloading", defaultValue: "Chromium is downloading (\(percent)). Try again when it’s ready.", bundle: .module)
    }
    static var downloadFailed: String {
        String(localized: "browser.engine.downloadFailed", defaultValue: "Chromium couldn’t download yet. cmux will try again.", bundle: .module)
    }
    static var fallbackStartFailed: String {
        String(localized: "browser.engine.fallback.startFailed", defaultValue: "Chromium couldn’t start, so this tab uses WebKit.", bundle: .module)
    }
    /// A restored Chromium tab whose Chromium failed to start (`CEFUnavailableReason.keepsChromiumTabsOutOfWebKit`).
    static var chromiumUnavailableRestoredTab: String {
        String(localized: "browser.engine.unavailable.restoredTab",
               defaultValue: "Chromium unavailable: this tab isn’t loaded, because WebKit would open it signed out. Quit and reopen cmux to load it.", bundle: .module)
    }
}
