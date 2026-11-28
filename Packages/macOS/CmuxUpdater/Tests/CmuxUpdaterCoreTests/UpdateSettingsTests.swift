import Foundation
import Testing
@testable import CmuxUpdaterCore
@testable import CmuxUpdaterTestSupport

@Suite(.serialized) struct UpdateSettingsTests {
    private func freshDefaults() throws -> (UserDefaults, String) {
        let suite = "cmux.updater.settings-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    @Test func staleDailyIntervalUpgradesEvenAfterTheV2Migration() throws {
        let (defaults, suite) = try freshDefaults()
        defer { TestDefaults.remove(suite) }
        defaults.set(true, forKey: UpdateSettings.migrationKey)
        defaults.set(86_400, forKey: UpdateSettings.scheduledCheckIntervalKey)

        UpdateSettings().apply(to: defaults)

        #expect(defaults.double(forKey: UpdateSettings.scheduledCheckIntervalKey) == 900)
        #expect(defaults.bool(forKey: UpdateSettings.intervalMigrationKey))
    }

    @Test func staleHourlyIntervalUpgradesToTheFreshnessDefault() throws {
        let (defaults, suite) = try freshDefaults()
        defer { TestDefaults.remove(suite) }
        defaults.set(true, forKey: UpdateSettings.migrationKey)
        defaults.set(3600, forKey: UpdateSettings.scheduledCheckIntervalKey)

        UpdateSettings().apply(to: defaults)

        #expect(defaults.double(forKey: UpdateSettings.scheduledCheckIntervalKey) == 900)
        #expect(defaults.bool(forKey: UpdateSettings.intervalMigrationKey))
    }

    @Test func intervalMigrationKeepsOtherChoicesAndRunsOnce() throws {
        let (defaults, suite) = try freshDefaults()
        defer { TestDefaults.remove(suite) }
        defaults.set(true, forKey: UpdateSettings.migrationKey)
        defaults.set(7200, forKey: UpdateSettings.scheduledCheckIntervalKey)

        UpdateSettings().apply(to: defaults)
        #expect(defaults.double(forKey: UpdateSettings.scheduledCheckIntervalKey) == 7200)

        // A daily interval chosen after the migration ran stays.
        defaults.set(86_400, forKey: UpdateSettings.scheduledCheckIntervalKey)
        UpdateSettings().apply(to: defaults)
        #expect(defaults.double(forKey: UpdateSettings.scheduledCheckIntervalKey) == 86_400)
    }

    @Test func intervalMigrationIsANoOpWhenTheHostChecksDaily() throws {
        let (defaults, suite) = try freshDefaults()
        defer { TestDefaults.remove(suite) }
        defaults.set(true, forKey: UpdateSettings.migrationKey)
        defaults.set(86_400, forKey: UpdateSettings.scheduledCheckIntervalKey)

        UpdateSettings(scheduledCheckInterval: 86_400).apply(to: defaults)

        #expect(defaults.double(forKey: UpdateSettings.scheduledCheckIntervalKey) == 86_400)
    }
}
