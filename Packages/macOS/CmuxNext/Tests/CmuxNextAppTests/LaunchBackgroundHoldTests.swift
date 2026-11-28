@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// CMUX-629 (Leo: "the other portions need to draw / technically only need to draw that one workspace open and the
/// sidebar / relaunches"): at launch, background work and the hidden page spares wait until the open workspace is
/// live (the launch settle, after the first window frame), and at the latest a backstop after the first window frame.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct LaunchBackgroundHoldTests {
    private static func settle(_ firstFrame: FirstFrameGate) -> LaunchSettle {
        LaunchSettle(reveal: LaunchReveal(deadline: .seconds(60)), firstFrame: firstFrame, imageHold: LaunchImageHold())
    }

    @Test func backgroundWorkWaitsForTheOpenWorkspaceNotTheFirstFrame() {
        let budget = MainFrameBudget()
        let firstFrame = FirstFrameGate(backstop: DemandTimer(owner: "test.firstFrame", clock: ManualClock()))
        let settle = Self.settle(firstFrame)
        let hold = LaunchBackgroundHold(budget: budget, timer: DemandTimer(owner: "test.hold", clock: ManualClock()))
        hold.install(settled: settle.whenSettled, firstFrame: firstFrame)
        var started: [String] = []
        hold.whenReleased { started.append("new tab spare") }
        hold.whenReleased { started.append("page host spare") }
        #expect(budget.holdsBackgroundForLaunch, "background work may run before the first window frame")
        firstFrame.open()
        #expect(budget.holdsBackgroundForLaunch, "the first window frame alone released background work: the open workspace is not live yet")
        #expect(started.isEmpty, "a hidden page spare started before the open workspace was live")
        settle.settle() // the first live terminal frame
        #expect(!budget.holdsBackgroundForLaunch)
        #expect(started == ["new tab spare", "page host spare"])
        hold.whenReleased { started.append("late") }
        #expect(started == ["new tab spare", "page host spare", "late"])
    }

    @Test func aSettleBeforeTheFirstWindowFrameReleasesAtThatFrame() {
        let budget = MainFrameBudget()
        let firstFrame = FirstFrameGate(backstop: DemandTimer(owner: "test.firstFrame", clock: ManualClock()))
        let settle = Self.settle(firstFrame)
        let hold = LaunchBackgroundHold(budget: budget, timer: DemandTimer(owner: "test.hold", clock: ManualClock()))
        hold.install(settled: settle.whenSettled, firstFrame: firstFrame)
        settle.settle() // a page pane shown first, inside applicationDidFinishLaunching
        #expect(budget.holdsBackgroundForLaunch, "background work released before the first window frame")
        firstFrame.open()
        #expect(!budget.holdsBackgroundForLaunch)
    }

    /// Demand beats the hold: a key or click before the open workspace is live (a Cmd-N, a new tab at the first frame
    /// plus 100 ms) ends it before the event is handled, so what the action needs is made in its own turn and nothing it
    /// needs waits behind the hold. The hidden spares start after that event's frame, never in the person's turn.
    @Test func aPersonsInputBeforeTheSettleEndsTheHoldAtOnce() {
        let budget = MainFrameBudget()
        let firstFrame = FirstFrameGate(backstop: DemandTimer(owner: "test.firstFrame", clock: ManualClock()))
        let settle = Self.settle(firstFrame)
        var marks: [String] = []
        let hold = LaunchBackgroundHold(budget: budget, timer: DemandTimer(owner: "test.hold", clock: ManualClock())) { marks.append($0) }
        hold.install(settled: settle.whenSettled, firstFrame: firstFrame)
        var started = 0
        hold.whenReleased { started += 1 }
        firstFrame.open()
        hold.noteInput() // Cmd-N at the first frame + 100 ms
        #expect(!budget.holdsBackgroundForLaunch, "a person's key waited behind the launch hold")
        #expect(marks == ["launch.background_released_by_input"])
        #expect(started == 0, "a hidden spare started in the person's own turn")
        let end = ContinuousClock.now + .seconds(5)
        while started == 0, ContinuousClock.now < end { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
        #expect(started == 1, "the hidden spares never started after the input's frame")
        settle.settle()
        #expect(started == 1)
        #expect(marks == ["launch.background_released_by_input"])
    }

    /// Stop condition: a launch that never settles (the daemon is absent and no window shows a live pane) still
    /// releases its background work, ``LaunchBackgroundHold/backstop`` after the first window frame, and not before.
    @Test func theBackstopReleasesALaunchThatNeverSettlesWithTheDaemonAbsent() async throws {
        let budget = MainFrameBudget()
        let clock = ManualClock()
        let firstFrame = FirstFrameGate(backstop: DemandTimer(owner: "test.firstFrame", clock: ManualClock()))
        let settle = Self.settle(firstFrame)
        let hold = LaunchBackgroundHold(budget: budget, timer: DemandTimer(owner: "test.hold", clock: clock))
        hold.install(settled: settle.whenSettled, firstFrame: firstFrame)
        var started = 0
        hold.whenReleased { started += 1 }
        firstFrame.open()
        try await clock.waitForSleeper()
        clock.advance(by: LaunchBackgroundHold.backstop - .milliseconds(1))
        for _ in 0..<20 { await Task.yield() }
        #expect(budget.holdsBackgroundForLaunch, "the backstop released early")
        clock.advance(by: .milliseconds(1))
        for _ in 0..<200 where budget.holdsBackgroundForLaunch { await Task.yield() }
        #expect(!budget.holdsBackgroundForLaunch, "a launch that never settles kept background work held")
        #expect(started == 1)
        settle.settle()
        #expect(started == 1, "a settle after the backstop ran the hidden spares again")
    }
}
