import Foundation
import Testing
@testable import CmuxUpdater

@Suite("Update settings background defaults")
struct UpdateSettingsBackgroundDefaultsTests {
    @Test func freshInstallStagesUpdatesAutomaticallyWithoutMeteredDownloads() throws {
        let suiteName = "cmux.updater.background-defaults.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        UpdateSettings().apply(to: defaults)

        #expect(defaults.bool(forKey: UpdateSettings.automaticChecksKey))
        #expect(defaults.bool(forKey: UpdateSettings.automaticallyUpdateKey))
        #expect(!defaults.bool(forKey: UpdateSettings.allowMeteredDownloadsKey))
        #expect(defaults.bool(forKey: UpdateSettings.backgroundDownloadsMigrationKey))
    }

    @Test func migrationsRunOnceThenPreserveUserChoices() throws {
        let suiteName = "cmux.updater.background-migration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: UpdateSettings.automaticChecksKey)
        defaults.set(false, forKey: UpdateSettings.automaticallyUpdateKey)
        defaults.set(true, forKey: UpdateSettings.allowMeteredDownloadsKey)
        defaults.set(0, forKey: UpdateSettings.scheduledCheckIntervalKey)

        UpdateSettings().apply(to: defaults)

        #expect(defaults.bool(forKey: UpdateSettings.automaticChecksKey))
        #expect(defaults.bool(forKey: UpdateSettings.automaticallyUpdateKey))
        #expect(!defaults.bool(forKey: UpdateSettings.allowMeteredDownloadsKey))
        #expect(defaults.double(forKey: UpdateSettings.scheduledCheckIntervalKey) == UpdateSettings().scheduledCheckInterval)

        defaults.set(false, forKey: UpdateSettings.automaticChecksKey)
        defaults.set(false, forKey: UpdateSettings.automaticallyUpdateKey)
        defaults.set(true, forKey: UpdateSettings.allowMeteredDownloadsKey)
        UpdateSettings().apply(to: defaults)

        #expect(!defaults.bool(forKey: UpdateSettings.automaticChecksKey))
        #expect(!defaults.bool(forKey: UpdateSettings.automaticallyUpdateKey))
        #expect(defaults.bool(forKey: UpdateSettings.allowMeteredDownloadsKey))
    }
}
