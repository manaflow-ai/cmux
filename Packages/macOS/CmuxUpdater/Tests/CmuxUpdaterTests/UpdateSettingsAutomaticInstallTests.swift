import Foundation
import Testing
@testable import CmuxUpdater

/// `SUAutomaticallyUpdate` is on by default: Sparkle downloads in the background and installs when
/// the user quits, never relaunching the app mid-session. Earlier builds stored `false` for everyone.
@Suite struct UpdateSettingsAutomaticInstallTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "cmux.update-settings-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func freshInstallDefaultsToAutomaticInstall() {
        let defaults = makeDefaults()
        UpdateSettings().apply(to: defaults)
        #expect(defaults.bool(forKey: UpdateSettings.automaticallyUpdateKey))
    }

    @Test func aStoredOldFalseTurnsOnOnceAndAnOptOutSticks() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: UpdateSettings.automaticallyUpdateKey)
        defaults.set(true, forKey: UpdateSettings.migrationKey)  // an install the earlier migrations already ran on
        UpdateSettings().apply(to: defaults)
        #expect(defaults.bool(forKey: UpdateSettings.automaticallyUpdateKey))

        defaults.set(false, forKey: UpdateSettings.automaticallyUpdateKey)
        UpdateSettings().apply(to: defaults)
        #expect(!defaults.bool(forKey: UpdateSettings.automaticallyUpdateKey))
    }
}
