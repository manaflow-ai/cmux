import Foundation
import Sentry
import Testing
@testable import CmuxNextCrashReporting

/// p08-startup-032: the handlers-first start (feature `sentryHandlersFirst`) keeps every crash
/// handler of the standard start and leaves out only the URLSession swizzle (network breadcrumbs
/// off, with tracing and failed-request capture already off). Session tracking and app-hang
/// tracking still install; app-hang reports are paused until `startDeferredIntegrations()`.
@Suite struct CrashReporterStartProfileTests {
    static let reporter = CrashReporter(policy: CrashReportingPolicy(
        bundleID: "com.cmuxterm.app.nightly", shortVersion: "1.0", build: "42", isDebugBuild: false,
        telemetryOptIn: true, managedDisablesTelemetry: false, processEnvironment: [:]))

    @Test func theStandardStartKeepsTheSDKDefaults() {
        let options = Self.reporter.options()
        #expect(options.enableCrashHandler)
        #expect(options.enableNetworkBreadcrumbs)
        #expect(options.enableAutoSessionTracking)
        #expect(options.enableAppHangTracking)
        #expect(options.appHangTimeoutInterval == 8.0)
    }

    @Test func theHandlersFirstStartKeepsCrashCaptureAndDropsOnlyTheNetworkSwizzle() {
        let standard = Self.reporter.options(profile: .standard)
        let first = Self.reporter.options(profile: .handlersFirst)
        #expect(first.enableCrashHandler == standard.enableCrashHandler)
        #expect(first.enableUncaughtNSExceptionReporting == standard.enableUncaughtNSExceptionReporting)
        #expect(first.dsn == standard.dsn)
        #expect(first.releaseName == standard.releaseName)
        #expect(first.environment == standard.environment)
        #expect(first.enableAutoSessionTracking == standard.enableAutoSessionTracking)
        #expect(first.enableAppHangTracking == standard.enableAppHangTracking)
        #expect(first.appHangTimeoutInterval == standard.appHangTimeoutInterval)
        // With these three off, SentryNetworkTrackingIntegration returns before it swizzles URLSession.
        #expect(!first.enableNetworkBreadcrumbs)
        #expect(!first.enableCaptureFailedRequests)
        #expect(first.tracesSampleRate?.doubleValue ?? 0 == 0)
    }

    @Test func theDeferredStartDoesNothingWhileSentryIsOff() {
        let off = CrashReporter(policy: CrashReportingPolicy(
            bundleID: "com.cmuxterm.app.nightly", shortVersion: "1.0", build: "42", isDebugBuild: false,
            telemetryOptIn: false, managedDisablesTelemetry: false, processEnvironment: [:]))
        #expect(!off.start(profile: .handlersFirst))
        off.startDeferredIntegrations()
        #expect(!off.isStarted)
    }
}
