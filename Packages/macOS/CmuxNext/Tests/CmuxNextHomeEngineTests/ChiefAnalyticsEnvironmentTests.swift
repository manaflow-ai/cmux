import Foundation
@testable import CmuxNextHomeEngine
import Testing

/// What the app tells the Chief host for its product analytics
/// (docs/posthog/chief-product-analytics.md): the person's telemetry choice,
/// this build's channel and version.
struct ChiefAnalyticsEnvironmentTests {
    private func defaults(_ name: String) throws -> UserDefaults {
        let suite = "ChiefAnalyticsEnvironmentTests.\(name).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func telemetryOffTurnsTheChiefsAnalyticsOff() throws {
        let off = try defaults("off")
        off.set(false, forKey: "sendAnonymousTelemetry")
        #expect(HomeBrainHost.analyticsEnvironment(bundle: .main, defaults: off)["CMUX_CHIEF_ANALYTICS"] == "off")
    }

    @Test func noChoiceOrOnLeavesItToTheHost() throws {
        let unset = try defaults("unset")
        #expect(HomeBrainHost.analyticsEnvironment(bundle: .main, defaults: unset)["CMUX_CHIEF_ANALYTICS"] == nil)
        let on = try defaults("on")
        on.set(true, forKey: "sendAnonymousTelemetry")
        #expect(HomeBrainHost.analyticsEnvironment(bundle: .main, defaults: on)["CMUX_CHIEF_ANALYTICS"] == nil)
    }

    @Test func theChannelComesFromTheBundleID() {
        #expect(HomeBrainHost.analyticsChannel(bundleID: "com.cmuxterm.app") == "stable")
        #expect(HomeBrainHost.analyticsChannel(bundleID: "com.cmuxterm.app.nightly") == "nightly")
        #expect(HomeBrainHost.analyticsChannel(bundleID: "com.cmuxterm.app.rc") == "rc")
        #expect(HomeBrainHost.analyticsChannel(bundleID: "com.cmuxterm.app.debug.my-tag") == "dev")
        #expect(HomeBrainHost.analyticsChannel(bundleID: "org.fork.app") == "dev")
        #expect(HomeBrainHost.analyticsChannel(bundleID: nil) == "dev")
    }
}
