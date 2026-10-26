import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileCrashReporting

@Suite @MainActor struct MobileFeedScrollSentryReporterTests {
    @Test func sendsOnlyConstantGroupingAndNumericContextAndHonorsOptOut() {
        let anomaly = MobileFeedScrollAnomaly(
            windowID: "2dcadcc5-4e91-4343-a48e-896889eb1e48", maxGapMilliseconds: 120,
            callbackCount: 600, itemCount: 400
        )
        var captures = 0
        for enabled in [true, false] {
            let reporter = MobileFeedScrollSentryReporter(consent: FixedConsent(enabled: enabled)) { event in
                captures += 1
                #expect(event.message?.formatted == "Feed scroll callback stall")
                #expect(event.fingerprint == ["ios-feed-scroll-callback-stall-v1"])
                #expect(event.context?["feed_performance"]?["window_id"] as? String == anomaly.windowID)
                #expect(event.context?["feed_performance"]?["callback_gap_max_ms"] as? Int == 120)
                #expect(event.context?["feed_performance"]?.count == 4)
                #expect(event.exceptions == nil)
                return String(repeating: "b", count: 32)
            }
            #expect((reporter.report(anomaly) != nil) == enabled)
        }
        #expect(captures == 1)
    }

    private struct FixedConsent: AnalyticsConsentProviding {
        let enabled: Bool
        var isTelemetryEnabled: Bool { enabled }
    }
}
