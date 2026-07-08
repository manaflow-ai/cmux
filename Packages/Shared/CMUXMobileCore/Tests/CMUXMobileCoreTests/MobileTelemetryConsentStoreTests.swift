import Foundation
import Testing

@testable import CMUXMobileCore

@Suite struct MobileTelemetryConsentStoreTests {
    private func makeDefaults(_ name: String) throws -> UserDefaults {
        let suiteName = "MobileTelemetryConsentStoreTests.\(name).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func defaultsToEnabledWithoutWriting() throws {
        let defaults = try makeDefaults("default")
        let store = MobileTelemetryConsentStore(defaults: defaults)
        #expect(store.isEnabled)
        #expect(defaults.object(forKey: MobileTelemetryConsentStore.defaultsKey) == nil)
    }

    @Test func persistsOptOutAndOptIn() throws {
        let defaults = try makeDefaults("persist")
        let store = MobileTelemetryConsentStore(defaults: defaults)
        store.setEnabled(false)
        #expect(!MobileTelemetryConsentStore(defaults: defaults).isEnabled)
        store.setEnabled(true)
        #expect(MobileTelemetryConsentStore(defaults: defaults).isEnabled)
    }
}
