import CmuxSentryReporting
import Foundation
import Sentry
import Testing
@testable import CmuxNextCrashReporting

/// Sentry adds no idle wakeup and no instrumentation the app does not use. Its
/// app-hang tracker (a thread that posts to the main queue every 1.6 s) is off wherever the main-thread watchdog is
/// the process's one hang watcher (its episodes are the app hangs, `AppHangReporter`), and every option the
/// short-lived CLI turns off (`CLISentryRuntimePolicy`) is off here too or kept for a named reason.
@Suite struct CrashReporterOptionsTests {
    @Test func theWatchdogTurnsSentrysAppHangTrackerOff() {
        let options = Self.reporter(.watchdog).options()
        #expect(!options.enableAppHangTracking, "SentryANRTrackerV1 would wake the main queue every 1.6 s")
        #expect(options.enableCrashHandler)
        #expect(options.enableUncaughtNSExceptionReporting)
    }

    @Test func withoutAWatchdogSentryStillReportsHangsAtEightSeconds() {
        let options = Self.reporter(.sentry).options()
        #expect(options.enableAppHangTracking)
        #expect(options.appHangTimeoutInterval == 8.0)
    }

    @Test func theWatchdogsAppHangThresholdIsTheSDKsFormerTimeout() {
        #expect(CrashReporter.appHangThreshold == .seconds(8))
        #expect(Self.reporter(.sentry).options().appHangTimeoutInterval == 8.0)
    }

    @Test func theReporterKeepsItsHangTracking() {
        #expect(Self.reporter(.watchdog).hangTracking == .watchdog)
        #expect(CrashReporter(policy: Self.policy).hangTracking == .sentry, "the default keeps Sentry's tracker")
    }

    @Test(arguments: [CrashReporter.HangTracking.sentry, .watchdog])
    func noAutoInstrumentationAndNoMetricKit(_ hangTracking: CrashReporter.HangTracking) {
        let options = Self.reporter(hangTracking).options()
        #expect(!options.isTracingEnabled)
        #expect(!options.enableAutoPerformanceTracing, "no network, file I/O or Core Data spans")
        #expect(!options.enableMetricKit)
        #expect(!options.enableLogs)
        #expect(!options.enableCaptureFailedRequests)
        // The two macOS swizzles the app uses: NSApplication reportException: and URLSession breadcrumbs.
        #expect(options.enableSwizzling)
        #expect(options.enableNetworkBreadcrumbs)
    }

    /// Each switch the CLI policy sets is the same here, or kept on for a reason the app has and a CLI run has not.
    @Test func everyCLIOffSwitchIsOffOrKeptForAReason() {
        let cli = Options()
        CLISentryRuntimePolicy().configure(cli)
        let app = Self.reporter(.watchdog).options()
        let same: [(String, KeyPath<Options, Bool>)] = [
            ("enableAppHangTracking", \.enableAppHangTracking),
            ("enableLogs", \.enableLogs),
            ("enableMetricKit", \.enableMetricKit),
        ]
        for (name, path) in same {
            #expect(app[keyPath: path] == cli[keyPath: path], "\(name)")
        }
        // Kept: sessions give crash-free rates (release health), which a CLI run has no lifecycle for.
        #expect(app.enableAutoSessionTracking && !cli.enableAutoSessionTracking)
        // Not compared: enableWatchdogTerminationTracking installs only on UIKit platforms, and shutdownTimeInterval
        // bounds SentrySDK.close, which the app never calls.
    }

    private static let policy = CrashReportingPolicy(
        bundleID: "com.cmuxterm.app.nightly", shortVersion: "1.0", build: "42", isDebugBuild: false,
        telemetryOptIn: true, managedDisablesTelemetry: false, processEnvironment: [:])

    private static func reporter(_ hangTracking: CrashReporter.HangTracking) -> CrashReporter {
        CrashReporter(policy: policy, hangTracking: hangTracking)
    }
}
