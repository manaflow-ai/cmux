import Foundation
@testable import CmuxNextHomeEngine
import Testing

/// What the app tells the Chief host for its product analytics
/// (docs/posthog/chief-product-analytics.md): the bundle id whose preferences
/// hold the telemetry choice, and the app's version.
struct ChiefAnalyticsEnvironmentTests {
    @Test func theHostGetsTheBundleIDAndVersion() {
        let variables = HomeBrainHost.analyticsEnvironment(bundle: .main)
        #expect(variables["CMUX_CHIEF_APP_BUNDLE_ID"] == Bundle.main.bundleIdentifier)
        #expect(variables["CMUX_CHIEF_APP_VERSION"] == Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        #expect(variables["CMUX_CHIEF_ANALYTICS"] == nil, "the host reads the choice itself, so a change reaches a running host")
    }
}
