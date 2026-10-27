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
        private(set) var replied = false

        /// The control reply's main-thread part: records that it ran.
        func reply() -> Bool {
            replied = true
            return true
        }
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

    /// p06 rule 9, the automation class of the control sweep: an agent's condition comes true and a control reply is
    /// posted (`mainWork.apply(.automation, owner:)`, as the barrier, billing and `updates.check` replies are) while
    /// the person's key waits for its frame. Neither runs in that key's turn nor on its frame; both run on the frame
    /// after its render pass closed the response.
    @Test func aWaitAndAnAutomationReplyYieldToThePersonsInputResponse() async {
        let rig = InputRig()
        defer { rig.stop() }
        let (gate, outcome) = (Gate(), Outcome())
        let waiting = Task { @MainActor in
            outcome.value = await ControlConditionWait(on: rig.work, owner: "test.wait").until { gate.open }
        }
        for _ in 0..<16 { await Task.yield() }
        #expect(outcome.value == nil, "the wait returned before its condition held")

        rig.work.noteDiscreteInput(expectsFrame: true)
        rig.work.causes.withCause(.automation) { gate.open = true }
        let reply = Task { @MainActor in await rig.work.apply(.automation, owner: "test.reply") { outcome.reply() } }
        for _ in 0..<64 where rig.work.postedCount(.automation) < 2 { await Task.yield() }
        #expect(rig.work.postedCount(.automation) == 2, "the wait's flush and the reply are not both posted as automation")

        let yielded = rig.work.budget.stats.yieldedToInputResponse[1]
        rig.turns.runAll()
        rig.frame()
        for _ in 0..<16 { await Task.yield() }
        #expect(rig.work.budget.isInputResponseOpen)
        #expect(!outcome.replied, "the reply ran inside the person's input response")
        #expect(outcome.value == nil, "the wait resumed inside the person's input response")
        #expect(rig.work.budget.stats.yieldedToInputResponse[1] > yielded, "the automation work never met the open response")

        rig.work.renderPassEnded(nanos: 1_000_000)
        #expect(!rig.work.budget.isInputResponseOpen, "the frame's render pass did not close the response")
        // Past the typing burst, so its one-task-per-interval rate plays no part.
        rig.clock.advance(ms: 600)
        rig.frame()
        #expect(outcome.replied, "the reply did not run on the frame after the response")
        #expect(await reply.value)
        await waiting.value
        #expect(outcome.value == true, "the wait did not resume on the frame after the response")
    }
}

/// A scheduler on a fake link kept up by a frame client, so posts wait for hand-fired frames, with a clock the test
/// moves and the scheduler's run loop turns run only when the test says.
@MainActor
private final class InputRig {
    let clock: WaitClock
    let turns: WaitTurns
    let work: MainWorkScheduler
    private let keeper: FrameClient
    private var timestamp: Double = 0

    init() {
        let clock = WaitClock(), turns = WaitTurns()
        self.clock = clock
        self.turns = turns
        work = MainWorkScheduler.testing(budget: MainFrameBudget(input: WaitNoInput(), uptimeNanos: clock.read),
                                         performTurn: turns.perform) { _ in WaitFakeLink() }
        keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        keeper.activate()
    }

    /// One display frame, a frame period after the last.
    func frame() {
        clock.advance(ms: 17)
        timestamp += 1
        work.frameDidFire(timestamp: timestamp, refreshInterval: 1.0 / 60)
    }

    func stop() { keeper.deactivate() }
}

/// The scheduler's run loop turns, run only when the test says (``MainWorkScheduler/TurnPerformer``).
@MainActor
private final class WaitTurns {
    private var queued: [@MainActor () -> Void] = []

    var perform: MainWorkScheduler.TurnPerformer { { [weak self] turn in self?.queued.append(turn) } }

    /// Runs the turns queued now.
    func runAll() {
        let turns = queued
        queued.removeAll()
        for turn in turns { turn() }
    }
}

/// A clock the test moves (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor
private final class WaitClock {
    private var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }
    func advance(ms: Double) { now += UInt64(ms * 1_000_000) }
}

/// No pending input: only the open input response holds automation.
@MainActor
private final class WaitNoInput: InputPendingSource {
    func hasPendingInput(uptime: TimeInterval) -> Bool { false }
}

@MainActor
private final class WaitFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
