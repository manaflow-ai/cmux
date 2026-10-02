import Foundation
import Testing
@testable import CmuxUpdater

@Suite struct UpdateSettingsTests {
    private func defaults() -> (UserDefaults, String) {
        let name = "cmux.updater.settings-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    @Test func backgroundDownloadOptInRepairsAnExistingDisabledValue() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: UpdateSettings.automaticallyUpdateKey)
        defaults.set(true, forKey: UpdateSettings.migrationKey)

        UpdateSettings(automaticallyDownloadsByDefault: true).apply(to: defaults)

        #expect(defaults.bool(forKey: UpdateSettings.automaticallyUpdateKey))
        #expect(defaults.bool(forKey: UpdateSettings.backgroundDownloadsMigrationKey))
    }

    @Test func defaultSettingsDoNotOptIntoBackgroundDownloads() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: UpdateSettings.automaticallyUpdateKey)
        defaults.set(true, forKey: UpdateSettings.migrationKey)

        UpdateSettings().apply(to: defaults)

        #expect(!defaults.bool(forKey: UpdateSettings.automaticallyUpdateKey))
        #expect(!defaults.bool(forKey: UpdateSettings.backgroundDownloadsMigrationKey))
    }
}
