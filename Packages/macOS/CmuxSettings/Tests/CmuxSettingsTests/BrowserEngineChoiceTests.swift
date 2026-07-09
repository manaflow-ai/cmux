import Foundation
import Testing
@testable import CmuxSettings

struct BrowserEngineChoiceTests {
    @Test func catalogKeyRoundTrips() async throws {
        let suiteName = "BrowserEngineChoiceTests-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsSettingsStore(defaults: try #require(UserDefaults(suiteName: suiteName)))
        let key = SettingCatalog().browser.engineChoice
        #expect(key.id == "browser.engine")
        let initial = await store.value(for: key)
        #expect(initial == .webkit)
        await store.set(.chromium, for: key)
        let updated = await store.value(for: key)
        #expect(updated == .chromium)
        let verify = try #require(UserDefaults(suiteName: suiteName))
        #expect(verify.string(forKey: "browserEngineOverride") == "chromium")
    }
}
