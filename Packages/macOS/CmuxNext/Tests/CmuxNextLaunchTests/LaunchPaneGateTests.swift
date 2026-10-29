import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The launch's hold on panes off screen (`launchVisiblePanesOnly`): it holds from launch
/// until startup completes, never with no scheduler or once quit began; a held pane's afterStartup post
/// runs only after completion; the views built while it holds are counted and reported once, at completion.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct LaunchPaneGateTests {
    /// How many times a post ran (a main-actor box: a post is `@Sendable`).
    @MainActor final class Runs {
        var count = 0
    }

    @Test func itHoldsFromLaunchUntilStartupCompletes() {
        let scheduler = StartupTestScheduler()
        let gate = LaunchPaneGate(startup: scheduler.startup, report: { _ in })
        #expect(gate.holdsPanes)
        scheduler.startup.finishRegistration()
        scheduler.startup.firstFrameCommitted()
        #expect(gate.holdsPanes, "the first frame is not the end of startup")
        scheduler.hand.drain()
        #expect(scheduler.startup.completion != nil)
        #expect(!gate.holdsPanes)
    }

    @Test func withNoSchedulerItHoldsAndCountsNothing() {
        let gate = LaunchPaneGate(startup: nil, report: { _ in Issue.record("a gate with no scheduler reported") })
        #expect(!gate.holdsPanes)
        gate.noteBuilt()
        #expect(gate.viewsBuilt == 0)
        let runs = Runs()
        gate.afterStartup { runs.count += 1 }
        #expect(runs.count == 0, "the feature off: nothing waits, so no post is made")
    }

    /// Acceptance: the views built before completion are counted and sent once, at completion; later builds are not.
    @Test func viewsBuiltBeforeCompletionAreReportedOnceAtCompletion() {
        let scheduler = StartupTestScheduler()
        var reports: [Int] = []
        let gate = LaunchPaneGate(startup: scheduler.startup, report: { reports.append($0) })
        gate.noteBuilt()
        scheduler.startup.finishRegistration()
        scheduler.startup.firstFrameCommitted()
        gate.noteBuilt()
        #expect(reports.isEmpty)
        scheduler.hand.drain()
        #expect(reports == [2])
        gate.noteBuilt()
        #expect(gate.viewsBuilt == 2, "a view built after completion counted")
        #expect(reports == [2])
    }

    /// The bench reads until `startup_complete`: the count goes out before it, though `LaunchOrder` registered first.
    @Test func theCountIsReportedBeforeTheCompletionMark() {
        let scheduler = StartupTestScheduler()
        var written: [String] = []
        scheduler.startup.whenComplete { _ in written.append("startup_complete") }
        let gate = LaunchPaneGate(startup: scheduler.startup, report: { written.append("\(LaunchPaneGate.viewsBuiltMark) \($0)") })
        gate.noteBuilt()
        scheduler.complete()
        #expect(written == ["launch.views_built 1", "startup_complete"])
    }

    @Test func aHeldPanesPostRunsOnlyAfterCompletion() {
        let scheduler = StartupTestScheduler()
        let gate = LaunchPaneGate(startup: scheduler.startup, report: { _ in })
        let runs = Runs()
        gate.afterStartup { runs.count += 1 }
        scheduler.startup.finishRegistration()
        scheduler.startup.firstFrameCommitted()
        for _ in 0..<4 { scheduler.fire() }
        #expect(runs.count == 0, "a held pane built before startup completed")
        scheduler.hand.drain()
        for _ in 0..<4 { scheduler.fire() }
        #expect(runs.count == 1)
    }

    @Test func aGateMadeAfterCompletionReportsNothing() {
        let scheduler = StartupTestScheduler()
        scheduler.complete()
        var reports: [Int] = []
        let gate = LaunchPaneGate(startup: scheduler.startup, report: { reports.append($0) })
        #expect(!gate.holdsPanes)
        gate.noteBuilt()
        #expect(reports.isEmpty && gate.viewsBuilt == 0)
    }

    @Test func quitEndsTheHoldAndRunsNoPost() {
        let scheduler = StartupTestScheduler()
        let gate = LaunchPaneGate(startup: scheduler.startup, report: { _ in Issue.record("quit reported a launch") })
        let runs = Runs()
        gate.afterStartup { runs.count += 1 }
        scheduler.startup.beginQuit()
        #expect(!gate.holdsPanes)
        scheduler.complete()
        for _ in 0..<4 { scheduler.fire() }
        #expect(runs.count == 0)
    }
}
