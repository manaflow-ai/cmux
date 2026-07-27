import Sentry
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

        MobileCrashReporter().startIfEnabled(
            consent: FixedConsent(isTelemetryEnabled: false),
            arguments: ["cmux", "--cmux-test-crash"],
            environment: [:],
            revocationWatcher: MobileCrashReporter.RevocationWatcher(),
            start: { _ in startCount += 1 },
            purgeCache: {},
            crash: { crashCount += 1 }
        )

        #expect(startCount == 0)
        #expect(crashCount == 0)
    }

    @Test func consentEnabledStartsExactlyOnce() {
        var startCount = 0
        var capturedOptions: Options?

        MobileCrashReporter().startIfEnabled(
            consent: FixedConsent(isTelemetryEnabled: true),
            arguments: ["cmux"],
            environment: [:],
            revocationWatcher: MobileCrashReporter.RevocationWatcher(),
            start: {
                capturedOptions = $0
                startCount += 1
            },
            close: {},
            purgeCache: {},
            crash: {}
        )

        #expect(startCount == 1)
        #expect(capturedOptions?.urlSession != nil)
        #expect(capturedOptions?.shutdownTimeInterval == 0)
    }

    @Test func optionsFactoryMatchesMobileContract() {
        let options = MobileCrashReporter().makeOptions()

        #expect(options.dsn == "https://ecba1ec90ecaee02a102fba931b6d2b3@o4507547940749312.ingest.us.sentry.io/4510796264636416")
        #expect(options.tracesSampleRate?.doubleValue == 0.0)
        #expect(options.sendDefaultPii == false)
        #expect(options.attachStacktrace == true)
        #expect(options.enableCaptureFailedRequests == false)
        #expect(options.enableWatchdogTerminationTracking == true)
        #expect(options.enableAppHangTracking == true)
        #expect(options.appHangTimeoutInterval == 8.0)
        #expect(options.enableSwizzling == false)
        #expect(options.enableNetworkTracking == false)
        #expect(options.enableNetworkBreadcrumbs == false)
        #expect(options.enableAutoBreadcrumbTracking == false)
        #expect(options.tracePropagationTargets.isEmpty)
        #expect(options.enableAutoSessionTracking == false)
        #if canImport(MetricKit) && !os(tvOS) && !os(visionOS)
        #expect(options.enableMetricKit == true)
        #expect(options.enableMetricKitRawPayload == false)
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

        MobileCrashReporter().startIfEnabled(
            consent: FixedConsent(isTelemetryEnabled: true),
            arguments: ["cmux", "--cmux-test-crash"],
            environment: [:],
            revocationWatcher: MobileCrashReporter.RevocationWatcher(),
            start: { _ in didStart = true },
            close: {},
            purgeCache: {},
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

        MobileCrashReporter().startIfEnabled(
            consent: FixedConsent(isTelemetryEnabled: true),
            arguments: ["cmux"],
            environment: [:],
            revocationWatcher: MobileCrashReporter.RevocationWatcher(),
            start: { _ in },
            close: {},
            purgeCache: {},
            crash: { crashCount += 1 }
        )

        #expect(crashCount == 0)
    }

    @Test(arguments: [
        ["XCTestConfigurationFilePath": "/tmp/cfg.xctestconfiguration"],
        ["XCTestBundlePath": "/tmp/tests.xctest"],
        ["XCTestSessionIdentifier": "ABC-123"],
        ["XCInjectBundleInto": "/tmp/host.app"],
        ["CMUX_UITEST_MOCK_MAC": "1"],
    ])
    func testRunEnvironmentDoesNotStart(environment: [String: String]) {
        var startCount = 0

        MobileCrashReporter().startIfEnabled(
            consent: FixedConsent(isTelemetryEnabled: true),
            arguments: ["cmux"],
            environment: environment,
            revocationWatcher: MobileCrashReporter.RevocationWatcher(),
            start: { _ in startCount += 1 },
            close: {},
            purgeCache: {},
            crash: {}
        )

        #expect(startCount == 0)
    }

    @Test func nonTestEnvironmentStarts() {
        var startCount = 0

        MobileCrashReporter().startIfEnabled(
            consent: FixedConsent(isTelemetryEnabled: true),
            arguments: ["cmux"],
            environment: ["PATH": "/usr/bin", "HOME": "/var/mobile"],
            revocationWatcher: MobileCrashReporter.RevocationWatcher(),
            start: { _ in startCount += 1 },
            close: {},
            purgeCache: {},
            crash: {}
        )

        #expect(startCount == 1)
    }

    @Test func consentDisabledAtLaunchPurgesCache() {
        let counter = CrashTestCounter()

        MobileCrashReporter().startIfEnabled(
            consent: FixedConsent(isTelemetryEnabled: false),
            arguments: ["cmux"],
            environment: [:],
            revocationWatcher: MobileCrashReporter.RevocationWatcher(),
            start: { _ in Issue.record("must not start") },
            purgeCache: { counter.increment() },
            crash: {}
        )

        #expect(counter.value == 1)
    }

    @Test func midSessionRevocationClosesSDKAndPurgesOnce() {
        let consent = CrashTestToggleConsent(enabled: true)
        let recorder = CrashTestSequenceRecorder()
        let revoked = DispatchSemaphore(value: 0)
        let center = NotificationCenter()
        let reporter = MobileCrashReporter(
            transportSessionController: CrashTestTransportController(recorder: recorder)
        )

        reporter.startIfEnabled(
            consent: consent,
            arguments: ["cmux"],
            environment: [:],
            notificationCenter: center,
            revocationWatcher: MobileCrashReporter.RevocationWatcher(),
            start: { _ in },
            close: {
                recorder.append("close")
                revoked.signal()
            },
            purgeCache: { recorder.append("purge") },
            crash: {}
        )
        #expect(recorder.sequence == ["transport-start"])
        recorder.removeAll()

        // Consent still on: defaults churn must not close the SDK.
        center.post(name: UserDefaults.didChangeNotification, object: nil)
        consent.enabled = false
        center.post(name: UserDefaults.didChangeNotification, object: nil)
        #expect(revoked.wait(timeout: .now() + 1) == .success)
        // Transport cancellation precedes close so close's mandatory flush
        // cannot upload queued or in-flight envelopes.
        #expect(recorder.sequence == ["transport-cancel", "purge", "close", "purge"])

    }

    @Test func launchReconcilesConsentRevokedWhileCrashSDKStarts() {
        let consent = CrashTestToggleConsent(enabled: true)
        let revoked = DispatchSemaphore(value: 0)
        let center = NotificationCenter()

        MobileCrashReporter().startIfEnabled(
            consent: consent,
            arguments: ["cmux"],
            environment: [:],
            notificationCenter: center,
            revocationWatcher: MobileCrashReporter.RevocationWatcher(),
            start: { _ in
                consent.setEnabled(false)
                center.post(name: UserDefaults.didChangeNotification, object: nil)
            },
            close: { revoked.signal() },
            purgeCache: {},
            crash: {}
        )

        #expect(revoked.wait(timeout: .now() + 1) == .success)
    }

    @Test func midSessionOptInStartsSDKWithoutRelaunch() {
        let consent = CrashTestToggleConsent(enabled: false)
        let counter = CrashTestCounter()
        let revoked = DispatchSemaphore(value: 0)
        let center = NotificationCenter()

        MobileCrashReporter().startIfEnabled(
            consent: consent,
            arguments: ["cmux"],
            environment: [:],
            notificationCenter: center,
            revocationWatcher: MobileCrashReporter.RevocationWatcher(),
            start: { _ in counter.increment() },
            close: { revoked.signal() },
            purgeCache: {},
            crash: {}
        )

        #expect(counter.value == 0)
        consent.enabled = true
        center.post(name: UserDefaults.didChangeNotification, object: nil)
        counter.waitForValue(1)
        #expect(counter.value == 1)

        // Unrelated defaults churn must not reinitialize a running SDK.
        center.post(name: UserDefaults.didChangeNotification, object: nil)
        consent.enabled = false
        center.post(name: UserDefaults.didChangeNotification, object: nil)
        #expect(revoked.wait(timeout: .now() + 1) == .success)
        #expect(counter.value == 1)
    }

    @Test func concurrentConsentTransitionsKeepSDKActionsInConsentOrder() {
        let consent = CrashTestToggleConsent(enabled: false)
        let recorder = CrashTestSequenceRecorder()
        let center = NotificationCenter()
        let enableEntered = DispatchSemaphore(value: 0)
        let allowEnableToFinish = DispatchSemaphore(value: 0)
        let enableFinished = DispatchSemaphore(value: 0)
        let revokeAttempted = DispatchSemaphore(value: 0)
        let revokeFinished = DispatchSemaphore(value: 0)

        MobileCrashReporter().startIfEnabled(
            consent: consent,
            arguments: ["cmux"],
            environment: [:],
            notificationCenter: center,
            revocationWatcher: MobileCrashReporter.RevocationWatcher(),
            start: { _ in
                enableEntered.signal()
                allowEnableToFinish.wait()
                recorder.append("enable")
            },
            close: { recorder.append("revoke") },
            purgeCache: {},
            crash: {}
        )

        consent.setEnabled(true)
        DispatchQueue.global().async {
            center.post(name: UserDefaults.didChangeNotification, object: nil)
            enableFinished.signal()
        }
        #expect(enableEntered.wait(timeout: .now() + 1) == .success)

        consent.setEnabled(false)
        DispatchQueue.global().async {
            revokeAttempted.signal()
            center.post(name: UserDefaults.didChangeNotification, object: nil)
            revokeFinished.signal()
        }
        #expect(revokeAttempted.wait(timeout: .now() + 1) == .success)
        // Notification delivery must not wait for Sentry lifecycle work.
        #expect(revokeFinished.wait(timeout: .now() + 1) == .success)
        #expect(recorder.sequence.isEmpty)

        allowEnableToFinish.signal()
        #expect(enableFinished.wait(timeout: .now() + 1) == .success)
        recorder.waitForCount(2)
        #expect(recorder.sequence == ["enable", "revoke"])
    }

    @Test func beforeSendDropsEventsWhenConsentRevokedMidSession() throws {
        let consent = CrashTestToggleConsent(enabled: true)
        var captured: Options?

        MobileCrashReporter().startIfEnabled(
            consent: consent,
            arguments: ["cmux"],
            environment: [:],
            revocationWatcher: MobileCrashReporter.RevocationWatcher(),
            start: { captured = $0 },
            close: {},
            purgeCache: {},
            crash: {}
        )

        let beforeSend = try #require(captured?.beforeSend)
        #expect(beforeSend(Event()) != nil)
        consent.enabled = false
        #expect(beforeSend(Event()) == nil)
    }
}
