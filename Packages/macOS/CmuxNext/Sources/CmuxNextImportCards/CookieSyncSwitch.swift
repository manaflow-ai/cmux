public import CmuxNextSettings
import CmuxNextCompat
import os

/// Reads, writes and follows `browser.import.cookieSync` (``BrowserCookieSyncSetting``): whether
/// imported cookies stay in sync. Keep in sync on the Import Cookies card writes the person's
/// answer; turning it off in Settings stops the watch.
@MainActor
public struct CookieSyncSwitch {
    private let settings: SettingsController

    /// - Parameter settings: The cmux.json the value is read from and written to.
    public init(settings: SettingsController) {
        self.settings = settings
    }

    /// Whether imported cookies stay in sync (on when the key is absent).
    public var isOn: Bool { settings.snapshot.browserImportCookieSync }

    /// Writes `on` unless the file already holds it, as the person (the card's checkbox) or the
    /// running action's caller.
    public func set(_ on: Bool) {
        guard isOn != on else { return }
        let writer = SettingWriter.currentRun()
        let settings = settings
        // task-owner: one cmux.json write the person asked for; `follow` applies it
        Task {
            do { try await settings.setSetting(at: BrowserCookieSyncSetting.configPath, to: .bool(on), by: writer) } catch {
                Logger(subsystem: "com.cmuxterm.app.next", category: "browser-import")
                    .error("browser.import.cookieSync write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Calls `changed` with each new value (the current one first).
    /// - Returns: The following task; cancel it when the settings are replaced.
    public func follow(_ changed: @escaping @MainActor (_ on: Bool) -> Void) -> Task<Void, Never> {
        let settings = settings
        // task-owner: the caller's (OnboardingService.cookieSyncFollow)
        return Task {
            for await on in ObservationStream({ settings.snapshot.browserImportCookieSync }) { changed(on) }
        }
    }
}
