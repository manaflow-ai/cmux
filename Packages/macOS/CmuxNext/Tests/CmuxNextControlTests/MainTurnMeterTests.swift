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
        #expect(snapshot.longestUnattributed.first?.unattributedNanos == 2 * Self.ms)
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
    /// loop's turns are its own, and the `sendEvent` span is closed while the loop runs. The menu's
    /// last turn goes on to `sendEvent`'s return, and the outer code's turn starts there.
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
        let longest = snapshot.longestUnattributed.first
        #expect(longest == MainTurnMeter.TopTurn(turnNanos: 4 * Self.ms, unattributedNanos: 3 * Self.ms, inputNanos: Self.ms,
                                                 endNanos: longest?.endNanos ?? 0, nested: true))
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

    /// A live resize or drag loop calls `nextEvent` once per event, so its nested loop exits and
    /// enters again around each event's work with no wait between: one nested level, one turn per
    /// wait, as at the top level, and no outer turn between the calls.
    @Test func aTrackingLoopsNextEventPerEventStaysOneNestedLevelWithOneTurnPerWait() {
        let clock = TurnClock()
        let turns = MainTurnMeter(uptimeNanos: clock.read)
        turns.loopEntered()
        turns.loopWoke()
        turns.loopWillExit()
        turns.loopExited()
        turns.inputDispatch {
            clock.advance(ms: 1)
            for _ in 0..<3 {
                turns.loopEntered()
                turns.loopWillWait()
                turns.loopDidRender()
                turns.loopWoke()
                clock.advance(ms: 1)
                turns.loopWillExit()
                turns.loopExited()
                // The resize handler's layout and display, between two nextEvent calls.
                clock.advance(ms: 5)
            }
        }
        turns.loopEntered()
        turns.loopWillWait()
        turns.loopDidRender()
        let snapshot = turns.snapshot()
        #expect(snapshot.turns == 6, "the mouse-down's turn, the first wait's, three 6 ms event turns, the turn after")
        #expect(snapshot.nestedTurns == 4)
        #expect(snapshot.turns - snapshot.nestedTurns == 2, "no outer turn between the nextEvent calls")
        #expect(snapshot.maxTurnNanos == 6 * Self.ms, "an event's 1 ms in the loop and its 5 ms handler are one turn")
        #expect(snapshot.inputNanos == 16 * Self.ms, "the handler's work is the sendEvent's")
        #expect(snapshot.unattributedNanos == 3 * Self.ms)
        #expect(snapshot.busyNanos == 19 * Self.ms, "every millisecond once")
    }

    /// A task that runs a nested loop (a CEF pump pass that runs a context menu): the loop's time is
    /// not the task's, a task run inside the loop is charged as itself, and while the loop runs the
    /// board names no task (Chrome's RunLevelTracker, base/task/sequence_manager/thread_controller.cc).
    @Test func aNestedLoopATaskRunsIsNotThatTasksTime() throws {
        let clock = TurnClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let turns = budget.turns
        let pump = budget.board.owner("cef.pump")
        var namedInMenu: MainTaskBoard.Task?
        var namedInMenuTask: MainTaskBoard.Task?
        turns.loopWoke()
        budget.run(.frame, owner: pump) {
            clock.advance(ms: 1)
            turns.loopEntered()
            namedInMenu = budget.board.running
            clock.advance(ms: 3_000)
            budget.run(.visible, owner: budget.board.owner("menu.item")) {
                namedInMenuTask = budget.board.running
                clock.advance(ms: 2)
            }
            #expect(budget.board.running == nil, "back in the menu: still no task")
            turns.loopExited()
            #expect(budget.board.running?.owner == "cef.pump", "the pass runs again after the menu")
            clock.advance(ms: 1)
        }
        turns.loopWillWait()
        turns.loopDidRender()
        #expect(namedInMenu == nil)
        #expect(namedInMenuTask?.owner == "menu.item")
        let snapshot = turns.snapshot()
        #expect(snapshot.tasks == 2)
        #expect(snapshot.maxTaskNanos == 2 * Self.ms, "the pass's own 2 ms and the menu item's 2 ms, not the menu's 3 s")
        let owners = budget.board.ownerSnapshot().owners
        let pass = try #require(owners.first { $0.owner == "cef.pump" })
        #expect(pass.runTotalNanos == 2 * Self.ms)
        let item = try #require(owners.first { $0.owner == "menu.item" })
        #expect(item.runTotalNanos == 2 * Self.ms)
        #expect(budget.stats.maxTaskNanos.allSatisfy { $0 <= 2 * Self.ms }, "the budget charges no class the menu")
    }

    /// AppKit catches an Objective-C exception thrown in a modal session run from `sendEvent` and goes
    /// on: the exception skipped the span's end and the loop's exit, and `reportException` resyncs.
    @Test func anExceptionUnwindGoesBackToTheTopLevel() {
        let clock = TurnClock()
        let turns = MainTurnMeter(uptimeNanos: clock.read)
        turns.loopEntered()
        turns.loopWoke()
        turns.loopWillExit()
        turns.loopExited()
        turns.beginSpan(.input, at: clock.read())
        turns.loopEntered()
        clock.advance(ms: 1)
        turns.unwindToTopLevel()
        let before = turns.snapshot()
        turns.loopEntered()
        turns.loopWillWait()
        clock.advance(ms: 2)
        turns.loopDidRender()
        turns.loopWoke()
        clock.advance(ms: 3)
        turns.loopWillWait()
        turns.loopDidRender()
        let after = turns.snapshot()
        #expect(after.turns == before.turns + 2)
        #expect(after.nestedTurns == before.nestedTurns, "the turns after the unwind are top-level ones")
        #expect(after.inputNanos == before.inputNanos, "the dead sendEvent span is not charged")
        #expect(after.renderNanos - before.renderNanos == 2 * Self.ms)
        #expect(after.unattributedNanos - before.unattributedNanos == 3 * Self.ms)
    }

    /// Work after the commit, as `AfterFrameCommit` and `MainRunLoopObserver.once(.., order: .max)`
    /// run it: a `.max` before-waiting observer added after the meter's still runs inside the turn.
    @Test func aMaxOrderObserverAddedAfterTheMeterRunsInsideTheTurn() {
        let clock = TurnClock()
        let turns = MainTurnMeter(uptimeNanos: clock.read)
        let mode = CFRunLoopMode("MainTurnMeterTests.afterCommit" as CFString)
        turns.observe(mode: mode)
        let late = MainRunLoopObserver(activities: .beforeWaiting, order: .max, mode: mode) { _ in
            clock.advance(ms: 2)
            CFRunLoopStop(CFRunLoopGetMain())
        }
        // A timer far off keeps the mode from being empty, so the loop reaches before-waiting.
        let keepAlive: CFRunLoopTimer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 60, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(CFRunLoopGetMain(), keepAlive, mode)
        _ = CFRunLoopRunInMode(mode, 5, false)
        CFRunLoopTimerInvalidate(keepAlive)
        late.invalidate()
        let snapshot = turns.snapshot()
        #expect(snapshot.turns == 1)
        #expect(snapshot.busyNanos == 2 * Self.ms, "the late observer's 2 ms are in the turn")
        #expect(snapshot.renderNanos == 2 * Self.ms)
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
        let top = turns.snapshot().longestUnattributed.map { $0.unattributedNanos / Self.ms }
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

    /// The app's meter (`signposts: true`) on turns over the 4 ms stall line: `stall.main_turn` goes to
    /// the trace ring as numbers, so the slow turn allocates nothing either.
    @Test func aStallTurnWithSignpostsAllocatesNothing() throws {
        let clock = TurnClock()
        let turns = MainTurnMeter(signposts: true, uptimeNanos: clock.read)
        let control = TurnMallocProbe.allocations { _ = ContiguousArray(repeating: 1, count: 64).count }
        try #require((control ?? 0) > 0, "malloc_logger saw no allocation on this thread: the probe cannot measure here")
        for _ in 0..<16 { stallTurn(turns, clock: clock) }
        let measured = try #require(TurnMallocProbe.allocations {
            for _ in 0..<500 { stallTurn(turns, clock: clock) }
        })
        #expect(measured == 0)
        #expect(turns.snapshot().turnsOverStall == 516)
    }

    /// One 5 ms turn: a 3 ms input dispatch and 2 ms of render.
    private func stallTurn(_ turns: MainTurnMeter, clock: TurnClock) {
        turns.loopWoke()
        turns.inputDispatch { clock.advance(ms: 3) }
        turns.loopWillWait()
        clock.advance(ms: 2)
        turns.loopDidRender()
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

    @Test func theReportKeepsEveryFieldAndAddsTheTurnFields() async throws {
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
        // debug.main_budget copies on main and folds the turns off it: the same report.
        let (fields, turns) = budget.reportParts
        let folded = await Task.detached { turns.report(merging: fields) }.value
        #expect(folded == budget.report)
        budget.resetStats()
        #expect(budget.turns.snapshot().turns == 0, "debug.main_budget reset clears the turns too")
    }

    /// A window's layout depth is counted only in the turn that began its pass, by
    /// this number: it holds through one turn (the render phase included) and moves when the next begins.
    @Test func theTurnNumberMovesOncePerTurn() {
        let clock = TurnClock()
        let turns = MainTurnMeter(uptimeNanos: clock.read)
        let before = turns.turnNumber
        turns.loopWoke()
        let first = turns.turnNumber
        #expect(first == before + 1)
        turns.inputDispatch { clock.advance(ms: 1) }
        turns.loopWillWait()
        #expect(turns.turnNumber == first, "the render phase is another turn")
        turns.loopDidRender()
        turns.loopWoke()
        #expect(turns.turnNumber == first + 1)
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
