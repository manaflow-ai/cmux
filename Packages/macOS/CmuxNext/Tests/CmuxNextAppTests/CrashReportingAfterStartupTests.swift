@testable import CmuxNextApp
import CmuxNextCrashReporting
import CmuxNextWakeups
import Testing

/// Feature `sentryHandlersFirst`: `AppCrashReporting` starts Sentry with the profile
/// `AppCrashReporting.AfterStartup` names and hands it the resume of what that start paused (app-hang
/// reports). On, the resume is one afterStartup post: never while the launch still loads, once after
/// startup completes, never after a quit before it. Off, nothing is paused, so nothing is posted or run.
@MainActor @Suite(.timeLimit(.minutes(1))) struct CrashReportingAfterStartupTests {
    @Test func withTheFeatureTheResumeRunsOnceAfterStartupCompletes() {
        let f = LaunchOrderFixture()
        let runs = AfterStartupRuns()
        let later = AppCrashReporting.AfterStartup(handlersFirst: true, startup: f.order.startup)
        #expect(later.profile == .handlersFirst)
        later.schedule { runs.count += 1 }
        let restore = f.order.startup.hold("WindowManager.restore")
        f.complete()
        for _ in 0..<3 { f.fire() }
        #expect(runs.count == 0, "app-hang reports resumed while a visible pane still loaded")
        restore.release(.visiblePaneLoadedIdle)
        f.hand.drain()
        for _ in 0..<3 { f.fire() }
        #expect(runs.count == 1)
        #expect(f.order.startup.log.records.map(\.name.description) == ["CrashReporting.afterStartup"])
    }

    @Test func withoutTheFeatureNothingIsPausedSoNothingIsPostedOrRun() {
        let f = LaunchOrderFixture()
        let runs = AfterStartupRuns()
        let later = AppCrashReporting.AfterStartup(handlersFirst: false, startup: f.order.startup)
        #expect(later.profile == .standard)
        later.schedule { runs.count += 1 }
        f.complete()
        f.hand.drain()
        for _ in 0..<3 { f.fire() }
        #expect(runs.count == 0)
        #expect(f.order.startup.log.records.isEmpty)
    }

    @Test func withTheFeatureAndNoLaunchSchedulerTheResumeRunsAtOnce() {
        let runs = AfterStartupRuns()
        AppCrashReporting.AfterStartup(handlersFirst: true, startup: nil).schedule { runs.count += 1 }
        #expect(runs.count == 1)
    }

    @Test func aQuitBeforeCompletionNeverRunsTheResume() {
        let f = LaunchOrderFixture()
        let runs = AfterStartupRuns()
        AppCrashReporting.AfterStartup(handlersFirst: true, startup: f.order.startup).schedule { runs.count += 1 }
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
