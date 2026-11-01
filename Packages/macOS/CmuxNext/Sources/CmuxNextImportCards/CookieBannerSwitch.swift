public import CmuxNextSettings
import CmuxNextCompat
import os

/// Reads, writes and follows `browser.import.cookieBanner` (``BrowserCookieBannerSetting``), the
/// Import Cookies banner's on/off: Don't Show Again writes `false`, Show Import Cookies Banner `true`.
///
/// ```swift
/// let banner = CookieBannerSwitch(settings: settings)
/// banner.set(false) // Don't Show Again
/// ```
@MainActor
public struct CookieBannerSwitch {
    private let settings: SettingsController

    /// - Parameter settings: The cmux.json the value is read from and written to.
    public init(settings: SettingsController) {
        self.settings = settings
    }

    /// Whether the banner may show (on when the key is absent).
    public var isOn: Bool { settings.snapshot.browserImportCookieBanner }

    /// Writes `shown` unless the file already holds it. A run of an action writes as its caller
    /// (`SettingWriter.currentRun`); a click on the banner writes as the person.
    public func set(_ shown: Bool) {
        guard isOn != shown else { return }
        let writer = SettingWriter.currentRun()
        let settings = settings
        // task-owner: one cmux.json write the person or caller asked for; `follow` applies it
        Task {
            do { try await settings.setSetting(at: BrowserCookieBannerSetting().configPath, to: .bool(shown), by: writer) } catch {
                Logger(subsystem: "com.cmuxterm.app.next", category: "browser-import")
                    .error("browser.import.cookieBanner write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Calls `changed` with each new value and the one before it (nil the first time).
    /// - Returns: The following task; cancel it when the settings are replaced.
    public func follow(_ changed: @escaping @MainActor (_ on: Bool, _ before: Bool?) -> Void) -> Task<Void, Never> {
        let settings = settings
        // task-owner: the caller's (OnboardingService.cookieBannerFollow)
        return Task {
            var last: Bool?
            for await on in ObservationStream({ settings.snapshot.browserImportCookieBanner }) {
                changed(on, last)
                last = on
            }
        }
    }
}
