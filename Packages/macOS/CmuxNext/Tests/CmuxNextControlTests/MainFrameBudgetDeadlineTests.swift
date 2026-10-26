import CmuxNextWakeups
import Foundation
import Testing

/// The frame deadline of the one main-thread scheduler (plans/cmux-next/chrome-parity/p03-rendering.md,
/// task 015): with render-pass history a tick's budgeted work stops at its target time less the p95
/// commit of the last 32 frames (`MainCommitMeter`); with none the fixed per-frame limit holds.
@MainActor @Suite(.timeLimit(.minutes(1))) struct MainFrameBudgetDeadlineTests {
    /// With render-pass history, a tick's scheduled work stops at its target time less the commit
    /// estimate (Chromium's main-frame deadline): 3 ms passes at 120 Hz stop it 5.33 ms after the
    /// tick, past the fixed 4 ms limit.
    @Test func aFrameDeadlineStopsScheduledWorkAtTheTargetLessTheCommitEstimate() {
        let clock = DeadlineClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read, mediaTime: clock.seconds)
        Self.measure(passes: Array(repeating: 3_000_000, count: 32), budget: budget, clock: clock)
        budget.beginFrame(timestamp: clock.seconds(), refreshInterval: 1.0 / 120)
        #expect(budget.commitEstimateNanos == 3_000_000)
        let request = budget.board.owner("workspace.move")
        #expect(budget.mayRun(.automation))
        budget.run(.automation, owner: request) { clock.advance(ms: 5.33) }
        #expect(budget.mayRun(.automation), "5.33 ms after the tick is before the deadline (8.33 ms less 3 ms)")
        clock.advance(ms: 0.01)
        #expect(!budget.mayRun(.automation), "the work went past the deadline the commit needs")
    }

    /// A long frame period does not make a long stall: at 60 Hz with 1 ms commits the deadline
    /// is the 8 ms pass target after the tick, not 15.67 ms.
    @Test func theDeadlineNeverPassesThePassTarget() {
        let clock = DeadlineClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read, mediaTime: clock.seconds)
        Self.measure(passes: Array(repeating: 1_000_000, count: 32), budget: budget, clock: clock)
        budget.beginFrame(timestamp: clock.seconds(), refreshInterval: 1.0 / 60)
        let request = budget.board.owner("workspace.move")
        budget.run(.automation, owner: request) { clock.advance(ms: 7.9) }
        #expect(budget.mayRun(.automation))
        clock.advance(ms: 0.2)
        #expect(!budget.mayRun(.automation), "scheduled work ran past the 8 ms pass target")
    }

    /// No render pass measured yet: no deadline, the fixed 4 ms of scheduled work per frame.
    @Test func withNoCommitHistoryTheFixedBudgetHolds() {
        let clock = DeadlineClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read, mediaTime: clock.seconds)
        let request = budget.board.owner("workspace.move")
        budget.beginFrame(timestamp: clock.seconds(), refreshInterval: 1.0 / 120)
        #expect(budget.commitEstimateNanos == nil)
        var ran = 0
        while budget.mayRun(.automation) {
            budget.run(.automation, owner: request) { clock.advance(ms: 0.5) }
            ran += 1
        }
        #expect(ran == 8, "\(ran) requests ran: the fixed 4 ms limit did not apply")
    }

    /// A pending key still preempts the batch before the deadline.
    @Test func pendingInputPreemptsWorkBeforeTheDeadline() {
        let clock = DeadlineClock()
        let input = DeadlineInputPending()
        let budget = MainFrameBudget(input: input, uptimeNanos: clock.read, mediaTime: clock.seconds)
        Self.measure(passes: Array(repeating: 1_000_000, count: 32), budget: budget, clock: clock)
        budget.beginFrame(timestamp: clock.seconds(), refreshInterval: 1.0 / 120)
        input.pending = true
        #expect(!budget.mayRun(.visible), "a pending key is dispatched before the batch")
        #expect(!budget.mayRun(.automation))
        #expect(budget.mayRun(.frame))
    }

    /// A tick delivered too late for its commit (1.33 ms left at 120 Hz, 3 ms commits) runs each
    /// class's first task only: the rest waits for the next frame.
    @Test func aLateTickRunsOnlyTheFirstTaskOfEachClass() {
        let clock = DeadlineClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read, mediaTime: clock.seconds)
        Self.measure(passes: Array(repeating: 3_000_000, count: 32), budget: budget, clock: clock)
        budget.beginFrame(timestamp: clock.seconds() - 0.007, refreshInterval: 1.0 / 120)
        let request = budget.board.owner("workspace.move")
        #expect(budget.mayRun(.automation))
        budget.run(.automation, owner: request) { clock.advance(ms: 0.1) }
        #expect(!budget.mayRun(.automation))
        #expect(budget.mayRun(.visible), "another class still makes progress this frame")
    }

    /// The estimate is the 95th percentile of the last 32 frames: one slow frame in 32 does not
    /// move it, two do, and frames older than 32 drop out.
    @Test func theCommitEstimateIsTheP95OfTheLast32Frames() {
        let clock = DeadlineClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read, mediaTime: clock.seconds)
        Self.measure(passes: Array(repeating: 2_000_000, count: 31) + [20_000_000], budget: budget, clock: clock)
        budget.beginFrame(timestamp: clock.seconds(), refreshInterval: 1.0 / 120)
        #expect(budget.commitEstimateNanos == 2_000_000)
        budget.noteRenderPass(nanos: 12_000_000)
        clock.advance(ms: 1000.0 / 120)
        budget.beginFrame(timestamp: clock.seconds(), refreshInterval: 1.0 / 120)
        #expect(budget.commitEstimateNanos == 12_000_000, "the second slow frame in 32 is the 95th percentile")
        Self.measure(passes: Array(repeating: 1_000_000, count: 32), budget: budget, clock: clock)
        budget.beginFrame(timestamp: clock.seconds(), refreshInterval: 1.0 / 120)
        #expect(budget.commitEstimateNanos == 1_000_000, "frames older than the last 32 still counted")
    }

    /// The app's path: the budgeted link's tick (its `targetTimestamp - timestamp` as the refresh
    /// interval) places the deadline, so a 120 Hz automation batch with 3 ms commits runs eleven
    /// 0.5 ms requests (to 5.33 ms), where the fixed limit ran eight.
    @Test func theBudgetedLinksTickPlacesTheDeadline() {
        let clock = DeadlineClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read, mediaTime: clock.seconds)
        let work = MainWorkScheduler.testing(budget: budget) { _ in DeadlineFrameLink() }
        let request = budget.board.owner("workspace.move")
        var ran = 0
        let batch = FrameClient(owner: "Control.frames", budgeted: .automation, on: work) { _, budget in
            while budget.mayRun(.automation) {
                budget.run(.automation, owner: request) { clock.advance(ms: 0.5) }
                ran += 1
            }
            return true
        }
        Self.measure(passes: Array(repeating: 3_000_000, count: 32), budget: budget, clock: clock)
        batch.activate()
        work.frameDidFire(timestamp: clock.seconds(), refreshInterval: 1.0 / 120)
        #expect(ran == 11, "\(ran) requests ran before the 5.33 ms deadline")
        batch.deactivate()
    }

    /// The tick's own `targetTimestamp` (task 012's `FrameTick`) places the deadline, not the refresh
    /// period: a 60 Hz tick due 1/120 s later with 3 ms commits stops at 5.33 ms (eleven requests),
    /// not at the 8 ms pass target a 60 Hz period gives (sixteen).
    @Test func theTicksTargetTimestampPlacesTheDeadline() {
        let clock = DeadlineClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read, mediaTime: clock.seconds)
        let work = MainWorkScheduler.testing(budget: budget) { _ in DeadlineFrameLink() }
        let request = budget.board.owner("workspace.move")
        var ran = 0
        let batch = FrameClient(owner: "Control.frames", budgeted: .automation, on: work) { _, budget in
            while budget.mayRun(.automation) {
                budget.run(.automation, owner: request) { clock.advance(ms: 0.5) }
                ran += 1
            }
            return true
        }
        Self.measure(passes: Array(repeating: 3_000_000, count: 32), budget: budget, clock: clock)
        batch.activate()
        let now = clock.seconds()
        work.frameDidFire(timestamp: now, refreshInterval: 1.0 / 60, targetTimestamp: now + 1.0 / 120)
        #expect(ran == 11, "\(ran) requests ran: the budget ignored the tick's target time")
        batch.deactivate()
    }

    /// Runs one 120 Hz frame per pass, each followed by its render pass, so the next frame records it.
    private static func measure(passes: [UInt64], budget: MainFrameBudget, clock: DeadlineClock) {
        for pass in passes {
            budget.beginFrame(timestamp: clock.seconds(), refreshInterval: 1.0 / 120)
            budget.noteRenderPass(nanos: pass)
            clock.advance(ms: 1000.0 / 120)
        }
    }
}

/// A clock the test moves: `CLOCK_UPTIME_RAW` nanoseconds, and the same instant in
/// `CACurrentMediaTime` seconds (one timebase on macOS).
@MainActor
private final class DeadlineClock {
    private var now: UInt64 = 1_000_000_000
    // Strong: a scheduler's stall timer can read the clock after its test returned.
    var read: () -> UInt64 { { [self] in self.now } }
    var seconds: () -> CFTimeInterval { { [self] in Double(self.now) / 1_000_000_000 } }
    func advance(ms: Double) { now += UInt64(ms * 1_000_000) }
}

@MainActor
private final class DeadlineInputPending: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}

@MainActor
private final class DeadlineFrameLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
