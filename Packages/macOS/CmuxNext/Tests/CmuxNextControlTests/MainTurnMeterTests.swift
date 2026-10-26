@testable import CmuxNextControl
import CmuxNextCompat
import CmuxNextSettings
import CmuxNextWakeups
import CoreFoundation
import Darwin
import Testing

/// The main run loop's turn meter (plans/cmux-next/chrome-parity/p06-scheduler.md, task 008): each
/// busy turn split into scheduled, render, input dispatch and unattributed time; only the innermost
/// nested loop's turn attributed; no allocation per turn; `debug.main_budget` only gains fields.
@MainActor @Suite(.timeLimit(.minutes(1))) struct MainTurnMeterTests {
    private static let ms: UInt64 = 1_000_000

    @Test func aThreeMillisecondTaskAndTwoUnattributedMillisecondsReportAShareOfPointFour() {
        let clock = TurnClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let turns = budget.turns
        turns.loopWoke()
        budget.run(.visible, owner: budget.board.owner("store")) { clock.advance(ms: 3) }
        clock.advance(ms: 2)
        turns.loopWillWait()
        turns.loopDidRender()
        let snapshot = turns.snapshot()
        #expect(snapshot.turns == 1)
        #expect(snapshot.busyNanos == 5 * Self.ms)
        #expect(snapshot.scheduledNanos == 3 * Self.ms)
        #expect(snapshot.unattributedNanos == 2 * Self.ms)
        #expect(abs(snapshot.unattributedShare - 0.4) < 1e-9)
        #expect(snapshot.tasks == 1)
        #expect(snapshot.maxTaskNanos == 3 * Self.ms)
        #expect(snapshot.topUnattributed.first?.unattributedNanos == 2 * Self.ms)
    }

    @Test func aTurnSplitsIntoScheduledRenderInputAndUnattributed() {
        let clock = TurnClock()
        let turns = MainTurnMeter(uptimeNanos: clock.read)
        turns.loopWoke()
        turns.inputDispatch { clock.advance(ms: 1) }
        clock.advance(ms: 0.5)
        turns.beginSpan(.scheduled, at: clock.read())
        clock.advance(ms: 2)
        turns.endTask(at: clock.read(), ownNanos: 2 * Self.ms)
        turns.loopWillWait()
        clock.advance(ms: 1.5)
        // A task an observer runs during the render phase stays scheduled time.
        turns.beginSpan(.scheduled, at: clock.read())
        clock.advance(ms: 1)
        turns.endTask(at: clock.read(), ownNanos: Self.ms)
        turns.loopDidRender()
        let snapshot = turns.snapshot()
        #expect(snapshot.inputNanos == Self.ms)
        #expect(snapshot.scheduledNanos == 3 * Self.ms)
        #expect(snapshot.renderNanos == 1_500_000)
        #expect(snapshot.unattributedNanos == 500_000)
        #expect(snapshot.busyNanos == 6 * Self.ms)
        #expect(snapshot.turnsOverStall == 1, "a 6 ms turn is over the 4 ms stall line")
    }

    @Test func nestedTasksChargeTheInnermostSpanOnce() {
        let clock = TurnClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        budget.turns.loopWoke()
        budget.turns.inputDispatch {
            clock.advance(ms: 1)
            budget.run(.automation, owner: budget.board.owner("control")) {
                clock.advance(ms: 1)
                budget.run(.visible, owner: budget.board.owner("row")) { clock.advance(ms: 2) }
            }
            clock.advance(ms: 1)
        }
        budget.turns.loopWillWait()
        budget.turns.loopDidRender()
        let snapshot = budget.turns.snapshot()
        #expect(snapshot.inputNanos == 2 * Self.ms)
        #expect(snapshot.scheduledNanos == 3 * Self.ms)
        #expect(snapshot.busyNanos == 5 * Self.ms)
        #expect(snapshot.unattributedNanos == 0)
        #expect(snapshot.tasks == 2)
        #expect(snapshot.maxTaskNanos == 2 * Self.ms, "a task's own time leaves out its nested tasks")
    }

    /// A menu or modal loop run from `sendEvent`: the outer turn ends at the nested entry, the inner
    /// loop's turns are its own, and the `sendEvent` span is closed for their time.
    @Test func aNestedLoopInsideSendEventIsTheInnerTurnsAndIsNotCountedTwice() {
        let clock = TurnClock()
        let turns = MainTurnMeter(uptimeNanos: clock.read)
        turns.loopEntered()
        turns.loopWoke()
        turns.loopWillExit()
        turns.loopExited()
        turns.inputDispatch {
            clock.advance(ms: 1)
            turns.loopEntered()
            clock.advance(ms: 2)
            turns.loopWillWait()
            clock.advance(ms: 0.5)
            turns.loopDidRender()
            turns.loopWoke()
            clock.advance(ms: 3)
            turns.loopWillExit()
            turns.loopExited()
            clock.advance(ms: 1)
        }
        turns.loopEntered()
        turns.loopWillWait()
        turns.loopDidRender()
        let snapshot = turns.snapshot()
        #expect(snapshot.turns == 4, "outer to the menu, two menu turns, outer after it")
        #expect(snapshot.nestedTurns == 2)
        #expect(snapshot.inputNanos == 2 * Self.ms, "sendEvent's own time only: 1 ms before the menu, 1 ms after")
        #expect(snapshot.unattributedNanos == 5 * Self.ms)
        #expect(snapshot.renderNanos == 500_000)
        #expect(snapshot.busyNanos == 7_500_000, "every millisecond once")
        #expect(snapshot.topUnattributed.first == MainTurnMeter.TopTurn(turnNanos: 3 * Self.ms, unattributedNanos: 3 * Self.ms,
                                                                          endNanos: snapshot.topUnattributed.first?.endNanos ?? 0, nested: true))
    }

    /// The same as a real `CFRunLoopRunInMode` on the main run loop, observed through the meter's own
    /// observers in a private mode.
    @Test func aRealNestedRunInModeInsideAnInputSpanIsAttributedToTheInnerTurn() {
        let clock = TurnClock()
        let turns = MainTurnMeter(uptimeNanos: clock.read)
        let mode = CFRunLoopMode("MainTurnMeterTests.nested" as CFString)
        turns.observe(mode: mode)
        turns.loopWoke()
        turns.inputDispatch {
            clock.advance(ms: 1)
            CFRunLoopPerformBlock(CFRunLoopGetMain(), mode.rawValue) {
                MainActor.assumeIsolated { clock.advance(ms: 3) }
            }
            _ = CFRunLoopRunInMode(mode, 0, false)
            clock.advance(ms: 1)
        }
        turns.loopWillWait()
        turns.loopDidRender()
        let snapshot = turns.snapshot()
        #expect(snapshot.nestedTurns == 1)
        #expect(snapshot.inputNanos == 2 * Self.ms, "the nested loop's 3 ms are not sendEvent's")
        #expect(snapshot.unattributedNanos == 3 * Self.ms)
        #expect(snapshot.busyNanos == 5 * Self.ms)
    }

    @Test func aTopLevelExitAndEntryStayInOneTurnAndTheExitCommitIsRender() {
        let clock = TurnClock()
        let turns = MainTurnMeter(uptimeNanos: clock.read)
        turns.loopEntered()
        turns.loopWoke()
        clock.advance(ms: 1)
        turns.loopWillExit()
        clock.advance(ms: 1)
        turns.loopExited()
        turns.inputDispatch { clock.advance(ms: 1) }
        turns.loopEntered()
        turns.loopWillWait()
        turns.loopDidRender()
        let snapshot = turns.snapshot()
        #expect(snapshot.turns == 1)
        #expect(snapshot.nestedTurns == 0)
        #expect(snapshot.renderNanos == Self.ms)
        #expect(snapshot.inputNanos == Self.ms)
        #expect(snapshot.unattributedNanos == Self.ms)
    }

    @Test func theTopUnattributedTurnsAreTheLongestEightLongestFirst() {
        let clock = TurnClock()
        let turns = MainTurnMeter(uptimeNanos: clock.read)
        for length in [3.0, 9, 1, 10, 4, 7, 2, 8, 6, 5] {
            turns.loopWoke()
            clock.advance(ms: length)
            turns.loopWillWait()
            turns.loopDidRender()
        }
        let top = turns.snapshot().topUnattributed.map { $0.unattributedNanos / Self.ms }
        #expect(top == [10, 9, 8, 7, 6, 5, 4, 3])
    }

    @Test func percentilesFoldFromTheFixedBuckets() {
        var buckets = [UInt32](repeating: 0, count: MainTurnMeter.Snapshot.bucketEdges.count + 1)
        buckets[MainTurnMeter.Snapshot.bucket(300_000)] = 98
        buckets[MainTurnMeter.Snapshot.bucket(3_000_000)] = 1
        buckets[MainTurnMeter.Snapshot.bucket(30 * Self.ms)] = 1
        #expect(MainTurnMeter.Snapshot.percentile(0.5, of: buckets, max: 30 * Self.ms) == 500_000)
        #expect(MainTurnMeter.Snapshot.percentile(0.99, of: buckets, max: 30 * Self.ms) == 4 * Self.ms)
        #expect(MainTurnMeter.Snapshot.percentile(1, of: buckets, max: 30 * Self.ms) == 30 * Self.ms, "capped at the max seen")
        #expect(MainTurnMeter.Snapshot.percentile(0.5, of: [UInt32](repeating: 0, count: buckets.count), max: 0) == 0)
        #expect(MainTurnMeter.Snapshot.bucket(4 * Self.ms) == MainTurnMeter.Snapshot.bucket(3_000_000), "4 ms is a bucket edge")
    }

    @Test func aTurnAllocatesNothing() throws {
        let clock = TurnClock()
        let read = clock.read
        let turns = MainTurnMeter(uptimeNanos: read)
        let control = TurnMallocProbe.allocations { _ = ContiguousArray(repeating: 1, count: 64).count }
        try #require((control ?? 0) > 0, "malloc_logger saw no allocation on this thread: the probe cannot measure here")
        // Warm up: the first turns fill the top-turn slots.
        for _ in 0..<16 { oneTurn(turns, clock: clock, read: read) }
        let measured = try #require(TurnMallocProbe.allocations {
            for _ in 0..<1_000 { oneTurn(turns, clock: clock, read: read) }
        })
        #expect(measured == 0)
        #expect(turns.snapshot().turns > 3_000)
    }

    /// One top-level turn with a task, a `sendEvent` that runs a nested loop, and a render phase.
    private func oneTurn(_ turns: MainTurnMeter, clock: TurnClock, read: () -> UInt64) {
        turns.loopEntered()
        turns.loopWoke()
        turns.beginSpan(.scheduled, at: read())
        clock.advance(ms: 0.5)
        turns.endTask(at: read(), ownNanos: 500_000)
        turns.inputDispatch {
            turns.loopEntered()
            clock.advance(ms: 0.25)
            turns.loopWillExit()
            turns.loopExited()
        }
        clock.advance(ms: 0.25)
        turns.loopWillExit()
        turns.loopExited()
        turns.loopWillWait()
        turns.loopDidRender()
    }

    @Test func theReportKeepsEveryFieldAndAddsTheTurnFields() throws {
        let clock = TurnClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        budget.turns.loopWoke()
        budget.run(.visible, owner: budget.board.owner("store")) { clock.advance(ms: 3) }
        clock.advance(ms: 2)
        budget.turns.loopWillWait()
        budget.turns.loopDidRender()
        let report = try #require(budget.report.objectValue)
        let existing: Set<String> = ["frames", "classes", "pending_input", "input_checks", "max_input_check_ms", "render_passes",
                                     "max_render_pass_ms"]
        #expect(existing.isSubset(of: Set(report.keys)))
        #expect(Set(report.keys).subtracting(existing) == ["turn_ms", "task_ms", "unattributed_share", "top_unattributed_turns"])
        #expect(report["unattributed_share"]?.doubleValue.map { abs($0 - 0.4) < 1e-9 } == true)
        #expect(report["turn_ms"]?["count"]?.intValue == 1)
        #expect(report["turn_ms"]?["max"]?.doubleValue == 5)
        #expect(report["task_ms"]?["count"]?.intValue == 1)
        #expect(report["top_unattributed_turns"]?.arrayValue?.first?["unattributed_ms"]?.doubleValue == 2)
        budget.resetStats()
        #expect(budget.turns.snapshot().turns == 0, "debug.main_budget reset clears the turns too")
    }
}

/// A clock the test moves (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor
private final class TurnClock {
    private var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }
    func advance(ms: Double) { now += UInt64(ms * 1_000_000) }
}

/// Counts the allocations one thread makes, through libmalloc's `malloc_logger` hook (the one malloc
/// stack logging uses), as FeatureListTests' probe does.
private struct TurnMallocProbe {
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    /// `MALLOC_LOG_TYPE_ALLOCATE` (libmalloc stack_logging.h).
    static let allocateType: UInt32 = 2
    static let count = Atomic<Int>(0)
    static let thread = Atomic<UInt64>(0)

    /// The allocations `body` makes on this thread, or nil when the hook is missing.
    static func allocations(_ body: () -> Void) -> Int? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        let slot = symbol.assumingMemoryBound(to: Logger?.self)
        var id: UInt64 = 0
        pthread_threadid_np(nil, &id)
        count.store(0, ordering: .relaxed)
        thread.store(id, ordering: .relaxed)
        let previous = slot.pointee
        slot.pointee = { type, _, _, _, _, _ in
            guard type & TurnMallocProbe.allocateType != 0 else { return }
            var id: UInt64 = 0
            pthread_threadid_np(nil, &id)
            if id == TurnMallocProbe.thread.load(ordering: .relaxed) { _ = TurnMallocProbe.count.wrappingAdd(1, ordering: .relaxed) }
        }
        body()
        slot.pointee = previous
        thread.store(0, ordering: .relaxed)
        return count.load(ordering: .relaxed)
    }
}
