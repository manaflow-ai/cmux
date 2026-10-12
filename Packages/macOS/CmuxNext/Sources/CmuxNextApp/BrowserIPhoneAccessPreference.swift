import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextSettings
import Observation

/// Chromium follows cmux.json `browser.allowIPhoneAccess` (read when
/// Chromium starts; `CEFEngine.allowsIPhoneAccess`).
@MainActor
enum BrowserIPhoneAccessPreference {
    static func follow(_ settings: SettingsController, cef: CEFEngine) {
        // The snapshot is loaded by now: set it before Chromium can start.
        cef.allowsIPhoneAccess = settings.snapshot.browserAllowsIPhoneAccess
        // task-owner: process-lifetime settings follower, like BrowserLinkClickPreference
        Task { [weak settings, weak cef] in
            guard let settings else { return }
            for await allowed in ObservationStream({ settings.snapshot.browserAllowsIPhoneAccess }) {
                cef?.allowsIPhoneAccess = allowed
            }
        }
    }
}
