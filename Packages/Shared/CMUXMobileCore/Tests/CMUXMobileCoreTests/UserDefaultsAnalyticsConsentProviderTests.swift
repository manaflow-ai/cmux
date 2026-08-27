import Foundation
import Testing

@testable import CMUXMobileCore

@Suite struct UserDefaultsAnalyticsConsentProviderTests {
    @Test func defaultsOffAndTracksLiveChanges() throws {
        let suiteName = "cmux.analytics-consent.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let consent = UserDefaultsAnalyticsConsentProvider(defaults: defaults)
        #expect(!consent.isTelemetryEnabled)

        defaults.set(true, forKey: UserDefaultsAnalyticsConsentProvider.telemetryKey)
        #expect(consent.isTelemetryEnabled)

        defaults.set(false, forKey: UserDefaultsAnalyticsConsentProvider.telemetryKey)
        #expect(!consent.isTelemetryEnabled)
    }
}
