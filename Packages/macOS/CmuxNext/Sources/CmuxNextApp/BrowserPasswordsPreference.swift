import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextSettings
import CmuxNextWakeups

/// `browser.passwords.offerToSave` and `.generate` reach Chromium (process-wide) when its engine is
/// built and on each change after that; following never builds it. `allowExport` is read by the
/// Passwords page when it exports.
@MainActor
enum BrowserPasswordsPreference {
    /// Starts following; the caller keeps the returned follower for as long as Chromium follows (the app's life).
    static func follow(_ settings: SettingsController, chromium: ChromiumEngineSlot, on mainWork: MainWorkScheduler) -> AnyObject {
        chromium.whenBuilt { [weak settings] cef in
            guard let settings else { return }
            let setting = BrowserPasswordsSetting.current(settings)
            cef.setPasswordPolicy(offerToSave: setting.offerToSave, generate: setting.generate)
        }
        // `background`: read at the next password form; nothing on screen waits for it.
        let policy = ServiceObservation(.background, owner: "BrowserPasswordsPreference", on: mainWork) {
            BrowserPasswordsSetting.current(settings)
        } apply: { [weak chromium] setting in
            chromium?.built?.setPasswordPolicy(offerToSave: setting.offerToSave, generate: setting.generate)
        }
        return policy
    }
}
