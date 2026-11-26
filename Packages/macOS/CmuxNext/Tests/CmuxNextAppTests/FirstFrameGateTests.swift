@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextWakeups
import Testing
import CmuxNextWakeupsTestSupport

/// Launch work behind the first window frame (perf-launch-memory).
@MainActor
@Suite struct FirstFrameGateTests {
    @Test func workWaitsForTheFirstFrameThenRunsOnceInOrder() {
        let gate = FirstFrameGate(backstop: DemandTimer(owner: "test", clock: ManualClock()))
        var ran: [String] = []
        gate.whenOpen { ran.append("updater") }
        gate.whenOpen { ran.append("warm-ups") }
        #expect(ran.isEmpty)
        gate.open()
        gate.open()
        #expect(ran == ["updater", "warm-ups"])
        gate.whenOpen { ran.append("late") }
        #expect(ran == ["updater", "warm-ups", "late"])
    }

    @Test func aLaunchWithNoWindowStillRunsTheWorkAfterTheBackstop() async throws {
        let clock = ManualClock()
        let gate = FirstFrameGate(backstop: DemandTimer(owner: "test", clock: clock))
        var ran = 0
        gate.whenOpen { ran += 1 }
        gate.armBackstop(after: .seconds(3))
        try await clock.waitForSleeper()
        #expect(ran == 0)
        clock.advance(by: .seconds(3))
        for _ in 0..<50 where !gate.isOpen { await Task.yield() }
        #expect(gate.isOpen)
        #expect(ran == 1)
    }

    /// A view's own launch work (Home's first conversation host, TopHomePageView) is never ahead of the
    /// first frame, nor inside the commit's completion that opens the gate; an open that needs it runs it now.
    @Test func aHoldRunsItsWorkAfterTheGateOpensNotInsideItAndRunNowRunsItOnce() {
        let hold = FirstFrameHold()
        var ran: [String] = []
        hold.run(after: nil) { ran.append("no gate") }
        #expect(ran == ["no gate"], "no gate (tests): at once")
        let gate = FirstFrameGate(backstop: DemandTimer(owner: "test", clock: ManualClock()))
        hold.run(after: gate) { ran.append("host") }
        hold.run(after: gate) { ran.append("second") }
        #expect(ran == ["no gate"], "ahead of the first frame")
        gate.open()
        #expect(ran == ["no gate"], "inside the completion that opened the gate")
        hold.runNow()
        hold.runNow()
        #expect(ran == ["no gate", "host"], "runNow: the held work once; work given while it was held: dropped")
        hold.run(after: gate) { ran.append("open gate") }
        #expect(ran == ["no gate", "host", "open gate"], "once the frame is in: at once")
    }

    @Test func theFirstFrameCancelsTheBackstop() async throws {
        let clock = ManualClock()
        let gate = FirstFrameGate(backstop: DemandTimer(owner: "test", clock: clock))
        var ran = 0
        gate.whenOpen { ran += 1 }
        gate.armBackstop(after: .seconds(3))
        try await clock.waitForSleeper()
        gate.open()
        clock.advance(by: .seconds(3))
        for _ in 0..<20 { await Task.yield() }
        #expect(ran == 1)
    }
}
