import Foundation
import Testing

@testable import CMUXMobileCore

@Suite struct MobileHapticFeedbackTests {
    private func makeDefaults(_ name: String) throws -> UserDefaults {
        let suiteName = "MobileHapticFeedbackTests.\(name).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func defaultsToEnabledWithoutWriting() throws {
        let defaults = try makeDefaults("default")
        let haptics = MobileHapticFeedback(defaults: defaults)

        #expect(haptics.isEnabled)
        #expect(defaults.object(forKey: MobileHapticFeedback.enabledDefaultsKey) == nil)
    }

    @Test func readsBothPersistedPreferenceValues() throws {
        let defaults = try makeDefaults("persistence")
        let haptics = MobileHapticFeedback(defaults: defaults)

        defaults.set(false, forKey: MobileHapticFeedback.enabledDefaultsKey)
        #expect(!haptics.isEnabled)

        defaults.set(true, forKey: MobileHapticFeedback.enabledDefaultsKey)
        #expect(haptics.isEnabled)
    }

    @Test func suppressesEmissionWhenDisabled() throws {
        let defaults = try makeDefaults("emission")
        let haptics = MobileHapticFeedback(defaults: defaults)
        var emissionCount = 0

        defaults.set(false, forKey: MobileHapticFeedback.enabledDefaultsKey)
        haptics.performIfEnabled {
            emissionCount += 1
        }
        #expect(emissionCount == 0)

        defaults.set(true, forKey: MobileHapticFeedback.enabledDefaultsKey)
        haptics.performIfEnabled {
            emissionCount += 1
        }
        #expect(emissionCount == 1)
    }
}
