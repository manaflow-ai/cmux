@testable import CmuxNextApp
import CmuxNextWakeups
import Testing

/// With feature `sentryHandlersFirst` (p08-startup-032), the crash reporting work that is not crash
/// capture (app-hang reports resume, the helper crash and panic forwarders start) is one afterStartup
/// post: it never runs while the launch still loads, runs once after startup completes, and runs at
/// once when there is no launch scheduler.
@MainActor @Suite(.timeLimit(.minutes(1))) struct CrashReportingAfterStartupTests {
    @Test func theDeferredWorkRunsOnceAfterStartupCompletes() {
        let f = LaunchOrderFixture()
        let runs = AfterStartupRuns()
        AppCrashReporting.AfterStartup { runs.count += 1 }.post(on: f.order.startup)
        let restore = f.order.startup.hold("WindowManager.restore")
        f.complete()
        for _ in 0..<3 { f.fire() }
        #expect(runs.count == 0, "crash reporting's deferred work ran while a visible pane still loaded")
        restore.release(.visiblePaneLoadedIdle)
        f.hand.drain()
        for _ in 0..<3 { f.fire() }
        #expect(runs.count == 1)
        #expect(f.order.startup.log.records.map(\.name.description) == ["CrashReporting.afterStartup"])
    }

    @Test func withoutALaunchSchedulerTheDeferredWorkRunsAtOnce() {
        let runs = AfterStartupRuns()
        AppCrashReporting.AfterStartup { runs.count += 1 }.post(on: nil)
        #expect(runs.count == 1)
    }

    @Test func aQuitBeforeCompletionNeverRunsTheDeferredWork() {
        let f = LaunchOrderFixture()
        let runs = AfterStartupRuns()
        AppCrashReporting.AfterStartup { runs.count += 1 }.post(on: f.order.startup)
        f.order.startup.beginQuit()
        f.complete()
        for _ in 0..<3 { f.fire() }
        #expect(runs.count == 0)
    }
}

@MainActor
private final class AfterStartupRuns {
    var count = 0
}
