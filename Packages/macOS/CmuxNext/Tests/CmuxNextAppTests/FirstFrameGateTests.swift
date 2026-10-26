import CmuxNextLaunch
import CmuxNextWakeups
import Testing
import CmuxNextWakeupsTestSupport

/// Launch work behind the first window frame (perf-launch-memory), on the launch's
/// `StartupScheduler` (p08-startup-012): afterFirstFrame posts, released by the first frame or by
/// the backstop, which never claims a committed frame.
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

    @Test func aLaunchWithNoWindowRunsTheWorkAfterTheBackstopAndCompletesAsNoWindow() async throws {
        let f = LaunchOrderFixture()
        let clock = ManualClock()
        let gate = FirstFrameGate(startup: f.order.startup, backstop: DemandTimer(owner: "test", clock: clock))
        let ran = FirstFrameRan()
        gate.whenOpen("Test.updater") { ran.names.append("updater") }
        gate.armBackstop(after: .seconds(3)) { .noWindow }
        f.order.startup.finishRegistration()
        try await clock.waitForSleeper()
        f.fire()
        #expect(ran.names.isEmpty)
        clock.advance(by: .seconds(3))
        for _ in 0..<50 where !gate.isOpen { await Task.yield() }
        #expect(gate.isOpen)
        f.fire()
        #expect(ran.names == ["updater"])
        f.hand.drain()
        #expect(f.order.startup.completion?.reason == .noWindow, "the backstop is no committed frame")
    }

    @Test func aBackstopWithNoReasonLeavesTheFirstFrameRefToTheLateFrame() async throws {
        let f = LaunchOrderFixture()
        let clock = ManualClock()
        let gate = FirstFrameGate(startup: f.order.startup, backstop: DemandTimer(owner: "test", clock: clock))
        let ran = FirstFrameRan()
        gate.whenOpen("Test.updater") { ran.names.append("updater") }
        gate.armBackstop(after: .seconds(3)) { nil }
        f.order.startup.finishRegistration()
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(3))
        for _ in 0..<50 where !gate.isOpen { await Task.yield() }
        f.fire()
        #expect(ran.names == ["updater"], "the work never waits for a frame that may not come")
        f.hand.drain()
        #expect(f.order.startup.completion == nil)
        #expect(f.order.startup.heldRefs == ["Startup.firstFrame"], "a missed deadline is not a committed frame")
        gate.open()
        f.hand.drain()
        #expect(f.order.startup.completion?.reason == .firstFrameCommitted)
        f.fire()
        #expect(ran.names == ["updater"], "the late frame runs nothing twice")
    }

    @Test func theFirstFrameCancelsTheBackstop() async throws {
        let f = LaunchOrderFixture()
        let clock = ManualClock()
        let gate = FirstFrameGate(startup: f.order.startup, backstop: DemandTimer(owner: "test", clock: clock))
        let ran = FirstFrameRan()
        var asked = false
        gate.whenOpen("Test.updater") { ran.names.append("updater") }
        gate.armBackstop(after: .seconds(3)) {
            asked = true
            return .noWindow
        }
        try await clock.waitForSleeper()
        gate.open()
        clock.advance(by: .seconds(3))
        for _ in 0..<20 { await Task.yield() }
        f.fire()
        f.fire()
        #expect(ran.names == ["updater"])
        #expect(!asked, "the cancelled backstop never ends the ref")
    }

    @Test func openedReturnsOnceTheGateOpens() async {
        let f = LaunchOrderFixture()
        let gate = FirstFrameGate(startup: f.order.startup, backstop: DemandTimer(owner: "test", clock: ManualClock()))
        let done = FirstFrameRan()
        // task-owner: the test; it ends when the gate opens
        let opened = Task {
            await gate.opened()
            done.names.append("opened")
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(done.names.isEmpty, "nothing returns before the first frame")
        gate.open()
        await opened.value
        #expect(done.names == ["opened"])
        await gate.opened() // already open: at once
    }

    @Test func openedStillReturnsAfterQuitBegan() async {
        let f = LaunchOrderFixture()
        let gate = FirstFrameGate(startup: f.order.startup, backstop: DemandTimer(owner: "test", clock: ManualClock()))
        // task-owner: the test; it ends when the gate opens
        let opened = Task { await gate.opened() }
        for _ in 0..<20 { await Task.yield() }
        f.order.startup.beginQuit()
        gate.open()
        await opened.value // the scheduler drops its posts at quit; the gate's wait is not one of them
    }
}

/// The names the posted work ran, in order.
@MainActor
private final class FirstFrameRan {
    var names: [String] = []
}
