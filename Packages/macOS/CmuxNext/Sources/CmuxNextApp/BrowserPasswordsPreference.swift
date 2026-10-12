import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextSettings

/// `browser.passwords.offerToSave` and `.generate` reach Chromium (process-wide) when the app
/// starts and on each change. `allowExport` is read by the Passwords page when it exports.
@MainActor
enum BrowserPasswordsPreference {
    static func follow(_ settings: SettingsController, cef: CEFEngine) {
        // task-owner: lives as long as the app's settings; both weak.
        Task { [weak settings, weak cef] in
            guard let settings else { return }
            for await setting in ObservationStream({ BrowserPasswordsSetting.current(settings) }) {
                guard let cef else { return }
                cef.setPasswordPolicy(offerToSave: setting.offerToSave, generate: setting.generate)
            }
        }
    }
}
