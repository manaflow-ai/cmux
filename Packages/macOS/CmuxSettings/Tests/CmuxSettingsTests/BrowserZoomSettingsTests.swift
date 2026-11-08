import Foundation
import Testing
@testable import CmuxSettings

@Suite("Browser zoom settings")
struct BrowserZoomSettingsTests {
    @Test func normalizationClampsAndRejectsNonFiniteValues() {
        let policy = BrowserZoomSettings()
        #expect(policy.normalized(nil) == 1.0)
        #expect(policy.normalized(.nan) == 1.0)
        #expect(policy.normalized(.infinity) == 1.0)
        #expect(policy.normalized(0.1) == 0.25)
        #expect(policy.normalized(9.0) == 5.0)
        #expect(policy.normalized(0.8) == 0.8)
    }

    @Test func currentReadsConfiguredUserDefaultsValue() {
        let suiteName = "BrowserZoomSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let policy = BrowserZoomSettings()
        defaults.set(0.8, forKey: BrowserZoomSettings.userDefaultsKey)
        #expect(policy.current(defaults: defaults) == 0.8)

        defaults.set(99.0, forKey: BrowserZoomSettings.userDefaultsKey)
        #expect(policy.current(defaults: defaults) == 5.0)
    }
}
