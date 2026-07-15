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
        #expect(!defaults.bool(forKey: "cmux.update.allowMeteredDownloads"))
    }
}
