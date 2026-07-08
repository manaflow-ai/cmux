import Testing

import CmuxMobileAnalytics
@testable import CmuxMobileCrashReporting

private struct FixedConsent: AnalyticsConsentProviding {
    let isTelemetryEnabled: Bool
}

@Suite struct MobileCrashReporterTests {
    @Test func consentDisabledDoesNotStart() {
        var startCount = 0
        var crashCount = 0

        MobileCrashReporter.startIfEnabled(
            consent: FixedConsent(isTelemetryEnabled: false),
            arguments: ["cmux", "--cmux-test-crash"],
            start: { _ in startCount += 1 },
            crash: { crashCount += 1 }
        )

        #expect(startCount == 0)
        #expect(crashCount == 0)
    }

    @Test func consentEnabledStartsExactlyOnce() {
        var startCount = 0

        MobileCrashReporter.startIfEnabled(
            consent: FixedConsent(isTelemetryEnabled: true),
            arguments: ["cmux"],
            start: { _ in startCount += 1 },
            crash: {}
        )

        #expect(startCount == 1)
    }

    @Test func optionsFactoryMatchesMobileContract() {
        let options = MobileCrashReporter.makeOptions()

        #expect(options.dsn == "https://ecba1ec90ecaee02a102fba931b6d2b3@o4507547940749312.ingest.us.sentry.io/4510796264636416")
        #expect(options.tracesSampleRate?.doubleValue == 0.0)
        #expect(options.sendDefaultPii == false)
        #expect(options.attachStacktrace == true)
        #expect(options.enableCaptureFailedRequests == false)
        #expect(options.enableWatchdogTerminationTracking == true)
        #expect(options.enableAppHangTracking == true)
        #expect(options.appHangTimeoutInterval == 8.0)
        #if canImport(MetricKit) && !os(tvOS) && !os(visionOS)
        #expect(options.enableMetricKit == true)
        #expect(options.enableMetricKitRawPayload == true)
        #endif
        #if DEBUG
        #expect(options.environment == "ios-development")
        #expect(options.debug == true)
        #else
        #expect(options.environment == "ios-production")
        #expect(options.debug == false)
        #endif
    }

    @Test func debugCrashArgumentTriggersInjectedCrashAfterStart() {
        var didStart = false
        var crashCount = 0

        MobileCrashReporter.startIfEnabled(
            consent: FixedConsent(isTelemetryEnabled: true),
            arguments: ["cmux", "--cmux-test-crash"],
            start: { _ in didStart = true },
            crash: {
                #expect(didStart)
                crashCount += 1
            }
        )

        #if DEBUG
        #expect(crashCount == 1)
        #else
        #expect(crashCount == 0)
        #endif
    }

    @Test func debugCrashArgumentAbsentDoesNotCrash() {
        var crashCount = 0

        MobileCrashReporter.startIfEnabled(
            consent: FixedConsent(isTelemetryEnabled: true),
            arguments: ["cmux"],
            start: { _ in },
            crash: { crashCount += 1 }
        )

        #expect(crashCount == 0)
    }
}
