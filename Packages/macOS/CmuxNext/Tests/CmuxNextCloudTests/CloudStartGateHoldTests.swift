import CmuxNextCloud
import CmuxNextWakeupsTestSupport
import os
import Testing

/// A composer Cloud start holds its machine in the start gate through its chat's first turn (cmux#45953, 2026-11-22: the
/// app's update restarted the machine's daemon two minutes into a start, after the start's own run had returned, and the
/// chat's first prompt never reached its agent). The hold ends at the first token or at its bound, whichever comes first.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct CloudStartGateHoldTests {
    @Test func aHoldKeepsTheMachineUntilItEndsAndEndingTwiceLeavesOnce() {
        let gate = CloudStartGate()
        gate.enter("vm_a") // another start on the same machine
        let hold = gate.hold("vm_a", clock: ManualClock())
        #expect(gate.contains("vm_a"))
        hold.end()
        hold.end()
        #expect(hold.ended)
        #expect(gate.contains("vm_a"), "the other start still holds it")
        gate.leave("vm_a")
        #expect(!gate.contains("vm_a"))
    }

    @Test func aHoldNobodyEndsEndsAtItsBound() async throws {
        let gate = CloudStartGate(), clock = ManualClock()
        let hold = gate.hold("vm_b", bound: .seconds(300), clock: clock)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(299))
        await Task.yield()
        #expect(gate.contains("vm_b"))
        clock.advance(by: .seconds(1))
        for _ in 0..<20 where !hold.ended { await Task.yield() }
        #expect(hold.ended)
        #expect(!gate.contains("vm_b"))
    }

    /// The send's first token ends the hold (``CloudSendTimeline/whenFinished(_:)``); a body added after the end runs at once.
    @Test func theFirstTokenEndsTheHold() async {
        let gate = CloudStartGate(), timeline = CloudSendTimeline()
        let hold = gate.hold("vm_c", until: timeline, clock: ManualClock())
        timeline.mark("open")
        #expect(gate.contains("vm_c"))
        timeline.mark(CloudSendTimeline.firstToken)
        for _ in 0..<20 where !hold.ended { await Task.yield() }
        #expect(!gate.contains("vm_c"))
        let late = OSAllocatedUnfairLock(initialState: 0)
        timeline.whenFinished { late.withLock { $0 += 1 } }
        #expect(late.withLock { $0 } == 1)
    }
}
