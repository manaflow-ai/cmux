import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextSettings

/// `browser.passwords.offerToSave` and `.generate` reach Chromium (process-wide) when its engine is
/// built and on each change after that; following never builds it. `allowExport` is read by the
/// Passwords page when it exports.
@MainActor
enum BrowserPasswordsPreference {
    static func follow(_ settings: SettingsController, chromium: ChromiumEngineSlot) {
        chromium.whenBuilt { [weak settings] cef in
            guard let settings else { return }
            let setting = BrowserPasswordsSetting.current(settings)
            cef.setPasswordPolicy(offerToSave: setting.offerToSave, generate: setting.generate)
        }
        // task-owner: lives as long as the app's settings; both weak.
        Task { [weak settings, weak chromium] in
            guard let settings else { return }
            for await setting in ObservationStream({ BrowserPasswordsSetting.current(settings) }) {
                guard let chromium else { return }
                chromium.built?.setPasswordPolicy(offerToSave: setting.offerToSave, generate: setting.generate)
            }
        }
    }
}
