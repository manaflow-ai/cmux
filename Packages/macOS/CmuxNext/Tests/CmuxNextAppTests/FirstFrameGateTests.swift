@testable import CmuxNextApp
import CmuxNextLaunch
import CmuxNextWakeups
import Testing
import CmuxNextWakeupsTestSupport

/// Launch work behind the first window frame (perf-launch-memory), on the launch's
/// `StartupScheduler` (p08-startup-012): afterFirstFrame posts, released by the first frame.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct FirstFrameGateTests {
    @Test func workWaitsForTheFirstFrameThenRunsOnceInOrder() {
        let f = LaunchOrderFixture()
        let gate = FirstFrameGate(startup: f.order.startup, backstop: DemandTimer(owner: "test", clock: ManualClock()))
        let ran = FirstFrameRan()
        gate.whenOpen("Test.updater") { ran.names.append("updater") }
        gate.whenOpen("Test.warmups") { ran.names.append("warm-ups") }
        f.fire()
        #expect(ran.names.isEmpty)
        gate.open()
        gate.open()
        f.fire()
        #expect(ran.names == ["updater", "warm-ups"])
        gate.whenOpen("Test.late") { ran.names.append("late") }
        f.fire()
        #expect(ran.names == ["updater", "warm-ups", "late"])
        #expect(!f.order.startup.heldRefs.contains("Startup.firstFrame"), "the first frame ended the scheduler's first-frame ref")
    }

    @Test func theWorkRunsAtTheVisibleClassNotInTheCommitsTurn() {
        let f = LaunchOrderFixture()
        let gate = FirstFrameGate(startup: f.order.startup, backstop: DemandTimer(owner: "test", clock: ManualClock()))
        let ran = FirstFrameRan()
        gate.whenOpen("Test.updater") { ran.names.append("updater") }
        gate.open()
        #expect(ran.names.isEmpty, "the commit's turn stays free: the work waits for the next frame")
        f.fire()
        #expect(ran.names == ["updater"])
    }

    @Test func aLaunchWithNoWindowStillRunsTheWorkAfterTheBackstop() async throws {
        let f = LaunchOrderFixture()
        let clock = ManualClock()
        let gate = FirstFrameGate(startup: f.order.startup, backstop: DemandTimer(owner: "test", clock: clock))
        let ran = FirstFrameRan()
        gate.whenOpen("Test.updater") { ran.names.append("updater") }
        gate.armBackstop(after: .seconds(3))
        try await clock.waitForSleeper()
        f.fire()
        #expect(ran.names.isEmpty)
        clock.advance(by: .seconds(3))
        for _ in 0..<50 where !gate.isOpen { await Task.yield() }
        #expect(gate.isOpen)
        f.fire()
        #expect(ran.names == ["updater"])
    }

    @Test func theFirstFrameCancelsTheBackstop() async throws {
        let f = LaunchOrderFixture()
        let clock = ManualClock()
        let gate = FirstFrameGate(startup: f.order.startup, backstop: DemandTimer(owner: "test", clock: clock))
        let ran = FirstFrameRan()
        gate.whenOpen("Test.updater") { ran.names.append("updater") }
        gate.armBackstop(after: .seconds(3))
        try await clock.waitForSleeper()
        gate.open()
        clock.advance(by: .seconds(3))
        for _ in 0..<20 { await Task.yield() }
        f.fire()
        f.fire()
        #expect(ran.names == ["updater"])
    }

    @Test func openedReturnsOnceTheFirstFrameReleasedTheWork() async {
        let f = LaunchOrderFixture()
        let gate = FirstFrameGate(startup: f.order.startup, backstop: DemandTimer(owner: "test", clock: ManualClock()))
        let done = FirstFrameRan()
        // task-owner: the test; it ends when the gate's post runs
        let opened = Task {
            await gate.opened()
            done.names.append("opened")
        }
        for _ in 0..<20 { await Task.yield() }
        f.fire()
        #expect(done.names.isEmpty, "nothing runs before the first frame")
        gate.open()
        while done.names.isEmpty {
            f.fire()
            await Task.yield()
        }
        await opened.value
        #expect(done.names == ["opened"])
    }
}

/// The names the posted work ran, in order.
@MainActor
private final class FirstFrameRan {
    var names: [String] = []
}
