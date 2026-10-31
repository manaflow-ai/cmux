@testable import CmuxNextApp
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
