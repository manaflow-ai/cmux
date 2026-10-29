import Foundation
import Sentry
import Testing
@testable import CmuxNextCrashReporting

/// Both start profiles use the same options, so the handlers-first start (feature
/// `sentryHandlersFirst`) keeps crash capture, session tracking, network breadcrumbs and app-hang
/// tracking; it only pauses app-hang reports until `resumeAfterStartup()`.
@Suite struct CrashReporterStartProfileTests {
    @Test func theOptionsKeepEveryIntegrationTheSDKInstallsAtStart() {
        let options = CrashReporter(policy: Self.policy(telemetryOptIn: true)).options()
        #expect(options.enableCrashHandler)
        #expect(options.enableNetworkBreadcrumbs, "URLSession breadcrumbs would be lost for the whole run")
        #expect(options.enableAutoSessionTracking)
        #expect(options.enableAppHangTracking)
        #expect(options.appHangTimeoutInterval == 8.0)
    }

    @Test func theResumeDoesNothingWhileSentryIsOff() {
        let off = CrashReporter(policy: Self.policy(telemetryOptIn: false))
        #expect(!off.start(profile: .handlersFirst))
        off.resumeAfterStartup()
        #expect(!off.isStarted)
    }

    private static func policy(telemetryOptIn: Bool) -> CrashReportingPolicy {
        CrashReportingPolicy(bundleID: "com.cmuxterm.app.nightly", shortVersion: "1.0", build: "42", isDebugBuild: false,
                             telemetryOptIn: telemetryOptIn, managedDisablesTelemetry: false, processEnvironment: [:])
    }
}
