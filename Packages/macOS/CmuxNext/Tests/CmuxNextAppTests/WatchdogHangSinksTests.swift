@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextCrashReporting
import Foundation
import Testing

/// Sentry's app-hang tracker is off wherever the watchdog's sinks are set (the
/// watchdog is the process's one hang watcher), and the watchdog's hang sinks are set before Sentry starts. Before
/// this, they were set in `WatchdogReporting.install`, well after the start, so a launch hang in between had no
/// report from either side.
struct WatchdogHangSinksTests {
    @Test func theTrackerIsOffWhereTheSinksAreSet() {
        #expect(WatchdogHangSinks(watchdog: MainThreadWatchdog()).hangTracking == .watchdog)
    }

    /// The sinks need no started Sentry: both are set while the reporter is still off, as at launch.
    @Test func bothSinksAreSetBeforeSentryStarts() {
        let watchdog = MainThreadWatchdog() // never started
        let reporter = CrashReporter(policy: LaunchHangChild.policy(), hangTracking: .watchdog)
        #expect(reporter.policy.shouldStart)
        WatchdogHangSinks(watchdog: watchdog).install(reporter: reporter)
        #expect(!reporter.isStarted)
        #expect(watchdog.onHang != nil, "a launch hang would reach no crash report")
        #expect(watchdog.onHangEpisode != nil, "a launch hang would reach no Sentry app hang")
    }

    /// Without consent the hang still goes to crash reporting, which sends nothing while Sentry is off.
    @Test func theSinksAreSetWithoutConsent() {
        let watchdog = MainThreadWatchdog()
        WatchdogHangSinks(watchdog: watchdog).install(reporter: CrashReporter(policy: LaunchHangChild.policy(optIn: false)))
        #expect(watchdog.onHang != nil)
        #expect(watchdog.onHangEpisode != nil)
    }

    /// Tests and other launches without a watchdog keep Sentry's tracker.
    @Test func withoutAWatchdogSentryKeepsItsTracker() {
        #expect(AppCrashReporting(environment: AppEnvironment.current([:])).reporter.hangTracking == .sentry)
    }
}

enum LaunchHangChild {
    /// A Nightly policy; with `optIn` it starts Sentry when asked (no test asks).
    static func policy(optIn: Bool = true) -> CrashReportingPolicy {
        CrashReportingPolicy(bundleID: "com.cmuxterm.app.nightly", shortVersion: "1.0", build: "42", isDebugBuild: false,
                             telemetryOptIn: optIn, managedDisablesTelemetry: false, processEnvironment: [:])
    }
}
