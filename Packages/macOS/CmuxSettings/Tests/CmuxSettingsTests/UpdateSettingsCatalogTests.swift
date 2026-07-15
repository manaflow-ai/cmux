import Foundation
import Testing
@testable import CmuxSettings

@Suite("Update settings catalog")
struct UpdateSettingsCatalogTests {
    @Test func defaultsStageUpdatesWithoutMeteredDownloads() throws {
        let suiteName = "cmux.settings.update-defaults.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let client = UserDefaultsSettingsClient(defaults: defaults)
        let app = AppCatalogSection()

        #expect(client.value(for: app.automaticUpdateChecks))
        #expect(client.value(for: app.automaticUpdateDownloads))
        #expect(!client.value(for: app.allowMeteredUpdateDownloads))
    }

    @Test func choicesUseSparkleAndCmuxPolicyKeys() throws {
        let suiteName = "cmux.settings.update-storage.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let client = UserDefaultsSettingsClient(defaults: defaults)
        let app = AppCatalogSection()

        client.set(false, for: app.automaticUpdateChecks)
        client.set(false, for: app.automaticUpdateDownloads)
        client.set(true, for: app.allowMeteredUpdateDownloads)

        #expect(defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool == false)
        #expect(defaults.object(forKey: "SUAutomaticallyUpdate") as? Bool == false)
        #expect(defaults.object(forKey: "cmux.update.allowMeteredDownloads") as? Bool == true)
    }
}
