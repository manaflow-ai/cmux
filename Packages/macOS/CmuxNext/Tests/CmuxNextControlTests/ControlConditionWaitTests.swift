@testable import CmuxNextControl
import CmuxNextWakeups
import Foundation
import Observation
import Testing

/// A control request's condition wait (plans/cmux-next/chrome-parity/p06-scheduler.md, FG307, recipes R-obs and
/// R-wait): it resumes in a posted automation task after the change that met its condition, never inside the
/// change's will-set nor on a change that leaves it false; a cancelled wait returns false and reads no more.
@MainActor @Suite(.serialized)
struct ControlConditionWaitTests {
    @MainActor @Observable final class Gate {
        var open = false
        var ticks = 0
    }

    @MainActor final class Outcome {
        var value: Bool?
        var reads = 0
    }

    /// A main-thread scheduler with no display link: a post runs on the next main run loop pass.
    private static func work() -> MainWorkScheduler {
        MainWorkScheduler.testing(budget: MainFrameBudget()) { _ in nil }
    }

    /// Lets started tasks run, then runs the main run loop's blocks (the scheduler's turns arrive there).
    private static func drain() async {
        for _ in 0..<3 {
            for _ in 0..<8 { await Task.yield() }
            spinMainRunLoop(passes: 4)
        }
    }

    @Test func aWaitResumesInAPostedTaskAfterTheChange() async {
        let (work, gate, outcome) = (Self.work(), Gate(), Outcome())
        let waiting = Task { @MainActor in
            outcome.value = await ControlConditionWait(on: work, owner: "test.wait").until { gate.open }
        }
        await Self.drain()
        #expect(outcome.value == nil, "the wait returned before its condition held")
        gate.open = true
        #expect(outcome.value == nil, "the wait resumed inside the change's will-set")
        await Self.drain()
        await waiting.value
        #expect(outcome.value == true)
    }

    @Test func changesThatLeaveTheConditionFalseDoNotResumeTheWait() async {
        let (work, gate, outcome) = (Self.work(), Gate(), Outcome())
        let waiting = Task { @MainActor in
            outcome.value = await ControlConditionWait(on: work, owner: "test.wait").until {
                _ = gate.ticks
                return gate.open
            }
        }
        await Self.drain()
        for _ in 0..<50 { gate.ticks += 1 }
        await Self.drain()
        #expect(outcome.value == nil, "a change that left the condition false resumed the wait")
        gate.open = true
        await Self.drain()
        await waiting.value
        #expect(outcome.value == true)
    }

    @Test func aMetConditionReturnsAtOnce() async {
        let gate = Gate()
        gate.open = true
        #expect(await ControlConditionWait(on: Self.work(), owner: "test.wait").until { gate.open })
    }

    @Test func aCancelledWaitReturnsFalseAndReadsNoMore() async {
        let (work, gate, outcome) = (Self.work(), Gate(), Outcome())
        let waiting = Task { @MainActor in
            await ControlConditionWait(on: work, owner: "test.wait").until {
                outcome.reads += 1
                return gate.open
            }
        }
        await Self.drain()
        waiting.cancel()
        await Self.drain()
        #expect(await waiting.value == false, "a cancelled wait did not return false")
        let reads = outcome.reads
        gate.open = true
        await Self.drain()
        #expect(outcome.reads == reads, "a cancelled wait read its condition again")
    }
}
