@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextCrashReporting
import Darwin
import Foundation
import Testing

/// Sentry's app-hang tracker is off wherever the watchdog's sinks are set (the
/// watchdog is the process's one hang watcher), and the watchdog's hang sinks are set before Sentry starts. Before
/// this, they were set in `WatchdogReporting.install`, well after the start, so a launch hang in between had no
/// report from either side.
struct WatchdogHangSinksTests {
    @Test func theTrackerIsOffWithOrWithoutTheFatalHangRecord() {
        let folder = FileManager.default.temporaryDirectory
        #expect(WatchdogHangSinks(watchdog: MainThreadWatchdog(), keepsFatalHangRecord: true, markerFolder: folder).hangTracking == .watchdog)
        #expect(WatchdogHangSinks(watchdog: MainThreadWatchdog(), keepsFatalHangRecord: false, markerFolder: folder).hangTracking == .watchdog)
    }

    /// The sinks need no started Sentry: both are set while the reporter is still off, as at launch.
    @Test func bothSinksAreSetBeforeSentryStarts() {
        let watchdog = MainThreadWatchdog() // never started
        let reporter = CrashReporter(policy: LaunchHangChild.policy(), hangTracking: .watchdog)
        #expect(reporter.policy.shouldStart)
        WatchdogHangSinks(watchdog: watchdog, keepsFatalHangRecord: true, markerFolder: FileManager.default.temporaryDirectory)
            .install(reporter: reporter)
        #expect(!reporter.isStarted)
        #expect(watchdog.onHang != nil, "a launch hang would reach no crash report")
        #expect(watchdog.onHangEpisode != nil, "a launch hang would reach no Sentry app hang")
        #expect(watchdog.fatalHangs != nil, "a launch hang the app does not survive would leave no record")
    }

    /// Without consent there is no fatal-hang record to send later, and without the feature none is kept; the hang
    /// still goes to crash reporting, which sends nothing while Sentry is off.
    @Test(arguments: zip([true, false], [false, true]))
    func noFatalHangRecordWithoutTheFeatureOrConsent(keeps: Bool, consented: Bool) {
        let watchdog = MainThreadWatchdog()
        let policy = LaunchHangChild.policy(optIn: consented)
        WatchdogHangSinks(watchdog: watchdog, keepsFatalHangRecord: keeps, markerFolder: FileManager.default.temporaryDirectory)
            .install(reporter: CrashReporter(policy: policy))
        #expect(watchdog.onHang != nil)
        #expect(watchdog.onHangEpisode != nil, "app hangs do not need the fatal-hang record")
        #expect(watchdog.fatalHangs == nil)
    }

    /// The finding's case: the app's run marker and Sentry's policy are in place, the sinks are set, Sentry has not
    /// started yet (it never does in the child), and the main thread hangs 3 s and is killed. The next launch finds one
    /// fatal-hang record for that run.
    @Test func aRunKilledInALaunchHangBeforeSentryStartsLeavesAFatalHangRecord() async throws {
        let directory = CrashChild.directory("launch-hang", parent: getpid())
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(processExitsWith: .signal(SIGKILL)) {
            await LaunchHangChild.hangThenGetKilled()
        }
        let previous = try #require(CrashChild.previous(in: directory), "the child left no run.json")
        let record = try #require(FatalHangRecorder.takePrevious(in: directory, run: (pid: previous.pid, launched: previous.launched)),
                                  "a launch hang before Sentry's start left no fatal-hang record")
        #expect(record.pid == previous.pid)
        #expect(record.elapsedNanos >= 2_000_000_000)
        #expect(!record.frames.isEmpty, "the record has no main-thread stack")
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

    /// The launch order of `AppCrashReporting`: the run marker, the watchdog, its sinks for a reporter that has not
    /// started, then a main thread that does not answer for 3 s (and until the record is on disk, at most 20 s), then
    /// SIGKILL.
    @MainActor
    static func hangThenGetKilled() async {
        let marker = await CrashChild.markRun("launch-hang")
        let folder = CrashChild.directory("launch-hang", parent: getppid())
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), logStalls: false, hangAssertThreshold: nil))
        let sinks = WatchdogHangSinks(watchdog: watchdog, keepsFatalHangRecord: true, markerFolder: folder)
        sinks.install(reporter: CrashReporter(policy: policy(), hangTracking: sinks.hangTracking))
        watchdog.start()
        let record = folder.appending(path: FatalHangRecorder.fileName(pid: getpid())).path
        let started = ContinuousClock.now
        while (ContinuousClock.now - started < .seconds(3))
            || (!FileManager.default.fileExists(atPath: record) && ContinuousClock.now - started < .seconds(20)) {}
        kill(getpid(), SIGKILL)
        withExtendedLifetime((marker, watchdog)) {}
    }
}
