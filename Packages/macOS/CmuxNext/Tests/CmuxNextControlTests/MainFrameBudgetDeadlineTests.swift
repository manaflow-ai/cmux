import CmuxNextWakeups
import Foundation
import Testing

/// The frame deadline of the one main-thread scheduler (plans/cmux-next/chrome-parity/p03-rendering.md,
/// task 015): with render-pass history a tick's budgeted work also stops in time for the commit (the
/// p95 of the last 32 frames' passes, `MainCommitMeter`, or the last pass when longer) to end by the
/// tick's target time and by the 8 ms pass target. The deadline only ever ends work earlier than the
/// fixed per-frame limit, which still holds; with no history only the fixed limit applies.
@MainActor @Suite(.timeLimit(.minutes(1))) struct MainFrameBudgetDeadlineTests {
    /// The deadline counts wall time from the tick, so the frame-locked work before the batch is
    /// inside it: at 120 Hz with 3 ms passes the pass must end by 8 ms (the pass target, sooner than
    /// the 8.33 ms target), so work stops 5 ms after the tick, and 2 ms of frame-locked work leaves
    /// the batch 3 ms of its fixed 4.
    @Test func aFrameDeadlineCountsTheFrameLockedWorkBeforeTheBatch() {
        let clock = DeadlineClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        Self.measure(passes: Array(repeating: 3_000_000, count: 32), budget: budget, clock: clock)
        budget.beginFrame(timestamp: clock.seconds(), refreshInterval: 1.0 / 120)
        #expect(budget.commitEstimateNanos == 3_000_000)
        let frameOwner = budget.board.owner("motion.frame")
        let request = budget.board.owner("workspace.move")
        budget.run(.frame, owner: frameOwner) { clock.advance(ms: 2) }
        #expect(budget.mayRun(.automation))
        budget.run(.automation, owner: request) { clock.advance(ms: 2.9) }
        #expect(budget.mayRun(.automation), "4.9 ms after the tick is before the deadline (8 ms less 3 ms)")
        clock.advance(ms: 0.2)
        #expect(!budget.mayRun(.automation), "the work went past the deadline the commit needs")
    }

    /// The deadline never gives more than the fixed limit: an on-time batch keeps its 4 ms (eight
    /// 0.5 ms requests) at 120 Hz with 3 ms passes and at 60 Hz with 1 ms passes, though the
    /// deadline is later (5 ms and 7 ms after the tick).
    @Test func theDeadlineNeverGivesMoreThanTheFixedLimit() {
        for (refresh, pass) in [(1.0 / 120, UInt64(3_000_000)), (1.0 / 60, UInt64(1_000_000))] {
            let clock = DeadlineClock()
            let budget = MainFrameBudget(uptimeNanos: clock.read)
            Self.measure(passes: Array(repeating: pass, count: 32), budget: budget, clock: clock)
            budget.beginFrame(timestamp: clock.seconds(), refreshInterval: refresh)
            let request = budget.board.owner("workspace.move")
            var ran = 0
            while budget.mayRun(.automation) {
                budget.run(.automation, owner: request) { clock.advance(ms: 0.5) }
                ran += 1
            }
            #expect(ran == 8, "\(ran) requests ran at \(1 / refresh) Hz with \(pass) ns passes: past the fixed 4 ms")
        }
    }

    /// A long frame period does not make a long pass: at 60 Hz with 1 ms commits the work ends by
    /// the 8 ms pass target less the commit (7 ms after the tick), not by the 16.67 ms target less it.
    @Test func theDeadlineIsThePassTargetLessTheCommit() {
        let clock = DeadlineClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        Self.measure(passes: Array(repeating: 1_000_000, count: 32), budget: budget, clock: clock)
        budget.beginFrame(timestamp: clock.seconds(), refreshInterval: 1.0 / 60)
        let frameOwner = budget.board.owner("motion.frame")
        let request = budget.board.owner("workspace.move")
        budget.run(.frame, owner: frameOwner) { clock.advance(ms: 4) }
        budget.run(.automation, owner: request) { clock.advance(ms: 2.9) }
        #expect(budget.mayRun(.automation), "6.9 ms after the tick is before 8 ms less the 1 ms commit")
        clock.advance(ms: 0.2)
        #expect(!budget.mayRun(.automation), "scheduled work ran past the 8 ms pass target less the commit")
    }

    /// One expensive commit lowers the very next tick, though the p95 of 32 frames does not move
    /// (31 frames of 1 ms, then one 9 ms pass): past the whole pass target, only the first task runs.
    @Test func oneExpensiveCommitLowersTheNextTickAtOnce() {
        let clock = DeadlineClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        Self.measure(passes: Array(repeating: 1_000_000, count: 31) + [9_000_000], budget: budget, clock: clock)
        budget.beginFrame(timestamp: clock.seconds(), refreshInterval: 1.0 / 60)
        #expect(budget.commitEstimateNanos == 1_000_000)
        let request = budget.board.owner("workspace.move")
        var ran = 0
        while budget.mayRun(.automation) {
            budget.run(.automation, owner: request) { clock.advance(ms: 0.5) }
            ran += 1
        }
        #expect(ran == 1, "\(ran) requests ran after a 9 ms commit: the frame's commit misses its vsync")
    }

    /// No render pass measured yet: no deadline, the fixed 4 ms of scheduled work per frame.
    @Test func withNoCommitHistoryTheFixedBudgetHolds() {
        let clock = DeadlineClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
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

    /// A window a request opened outside any tick keeps what it spent when the tick comes within
    /// one period: its 4 ms of automation leave nothing for the tick's deadline to add.
    @Test func aWindowOpenedBeforeTheTickKeepsWhatItSpent() {
        let clock = DeadlineClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        Self.measure(passes: Array(repeating: 3_000_000, count: 32), budget: budget, clock: clock)
        clock.advance(ms: 1)
        let request = budget.board.owner("workspace.move")
        var ran = 0
        while budget.mayRun(.automation) {
            budget.run(.automation, owner: request) { clock.advance(ms: 0.5) }
            ran += 1
        }
        #expect(ran == 8, "the off-tick window did not get the fixed 4 ms")
        clock.advance(ms: 1)
        budget.beginFrame(timestamp: clock.seconds(), refreshInterval: 1.0 / 120)
        #expect(!budget.mayRun(.automation), "the tick's deadline gave the window a second budget")
        #expect(budget.mayRun(.visible), "another class's first task still runs")
    }

    /// A pending key still preempts the batch before the deadline.
    @Test func pendingInputPreemptsWorkBeforeTheDeadline() {
        let clock = DeadlineClock()
        let input = DeadlineInputPending()
        let budget = MainFrameBudget(input: input, uptimeNanos: clock.read)
        Self.measure(passes: Array(repeating: 1_000_000, count: 32), budget: budget, clock: clock)
        budget.beginFrame(timestamp: clock.seconds(), refreshInterval: 1.0 / 120)
        input.pending = true
        #expect(!budget.mayRun(.visible), "a pending key is dispatched before the batch")
        #expect(!budget.mayRun(.automation))
        #expect(budget.mayRun(.frame))
    }

    /// A tick that runs on main too late for its commit (7 ms after its frame time at 120 Hz, with
    /// 3 ms commits) runs each class's first task only: the rest waits for the next frame.
    @Test func aLateTickRunsOnlyTheFirstTaskOfEachClass() {
        let clock = DeadlineClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        Self.measure(passes: Array(repeating: 3_000_000, count: 32), budget: budget, clock: clock)
        budget.beginFrame(timestamp: clock.seconds() - 0.007, refreshInterval: 1.0 / 120, ranAt: clock.seconds())
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
        let budget = MainFrameBudget(uptimeNanos: clock.read)
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

    /// The app's path: the budgeted link's tick places the deadline from the time the tick ran on
    /// the scheduler's display clock, so a 120 Hz frame whose frame-locked client took 2 ms, with
    /// 3 ms commits, runs six 0.5 ms requests (to 5 ms after the tick), where the fixed limit ran eight.
    @Test func theBudgetedLinksTickPlacesTheDeadline() {
        let clock = DeadlineClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let work = MainWorkScheduler.testing(budget: budget, mediaTime: clock.seconds) { _ in DeadlineFrameLink() }
        let request = budget.board.owner("workspace.move")
        var ran = 0
        let motion = FrameClient(owner: "test.motion", isAnimation: false, on: work.frames) { _ in
            clock.advance(ms: 2)
            return true
        }
        let batch = FrameClient(owner: "Control.frames", budgeted: .automation, on: work) { _, budget in
            while budget.mayRun(.automation) {
                budget.run(.automation, owner: request) { clock.advance(ms: 0.5) }
                ran += 1
            }
            return true
        }
        Self.measure(passes: Array(repeating: 3_000_000, count: 32), budget: budget, clock: clock)
        motion.activate()
        batch.activate()
        work.frameDidFire(timestamp: clock.seconds(), refreshInterval: 1.0 / 120)
        #expect(ran == 6, "\(ran) requests ran before the 5 ms deadline")
        batch.deactivate()
        motion.deactivate()
    }

    /// The tick's own `targetTimestamp` (task 012's `FrameTick`) places the deadline, not the refresh
    /// period: a 60 Hz tick due 1/240 s later with 1 ms commits stops at 3.17 ms (seven requests),
    /// not at the fixed 4 ms its 60 Hz period leaves (eight).
    @Test func theTicksTargetTimestampPlacesTheDeadline() {
        let clock = DeadlineClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let work = MainWorkScheduler.testing(budget: budget, mediaTime: clock.seconds) { _ in DeadlineFrameLink() }
        let request = budget.board.owner("workspace.move")
        var ran = 0
        let batch = FrameClient(owner: "Control.frames", budgeted: .automation, on: work) { _, budget in
            while budget.mayRun(.automation) {
                budget.run(.automation, owner: request) { clock.advance(ms: 0.5) }
                ran += 1
            }
            return true
        }
        Self.measure(passes: Array(repeating: 1_000_000, count: 32), budget: budget, clock: clock)
        batch.activate()
        let now = clock.seconds()
        work.frameDidFire(timestamp: now, refreshInterval: 1.0 / 60, targetTimestamp: now + 1.0 / 240)
        #expect(ran == 7, "\(ran) requests ran: the budget ignored the tick's target time")
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
/// `CACurrentMediaTime` seconds (one timebase on macOS), for the display clock's ticks.
@MainActor
private final class DeadlineClock {
    private var now: UInt64 = 1_000_000_000
    // Strong: a scheduler's stall timer can read the clock after its test returned.
    var read: () -> UInt64 { { [self] in self.now } }
    var seconds: @MainActor () -> CFTimeInterval { { [self] in Double(self.now) / 1_000_000_000 } }
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
