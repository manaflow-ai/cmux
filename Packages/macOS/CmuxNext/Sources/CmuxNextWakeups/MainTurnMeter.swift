public import CoreFoundation
import CmuxNextCompat
import CmuxNextSignposts
import Darwin

/// Times every busy turn of the main run loop and splits it into scheduled work, render, input
/// dispatch and unattributed time (plans/cmux-next/chrome-parity/p06-scheduler.md, "Attribution").
///
/// A turn starts when the run loop wakes (after-waiting) and ends at the end of its before-waiting
/// phase (layout, display, the Core Animation commit and every later observer: the meter's end has
/// the one order above ``MainRunLoopObserver/lastOrder``), or at a nested loop's boundary. AppKit's
/// own loop leaves the run loop to dispatch each event (`nextEvent`, then `sendEvent`) and enters it
/// again: that exit and entry stay inside one turn, and the exit's commit counts as render.
///
/// Nested run loops (menu tracking, modal sessions, live resize, drag loops) are Chromium's run
/// levels (base/task/sequence_manager/thread_controller.h, `RunLevelTracker`; the observers are
/// base/message_loop/message_pump_apple.mm's `EnterExitObserver`): a loop entered while a span is
/// open or from inside another loop is nested, and only the innermost level's turn is attributed.
/// Its first entry ends the turn that was running and starts the inner one. The spans open then
/// (the `sendEvent` that runs a menu) are closed while the inner loop runs, so no time is counted
/// twice. A session calls `nextEvent` once per event, so its loop exits and enters again around
/// each event's work: that stays one nested level and one turn, as at the top level. The level ends,
/// and a turn of the outer code starts, when the span that entered it closes (the menu or modal
/// returns) or the outer loop goes on.
///
/// Attribution comes from spans: ``MainFrameBudget/run(_:owner:_:)`` opens a ``Span/scheduled`` span
/// per task, and the app's `sendEvent` runs inside ``inputDispatch(_:)``. Time goes to the innermost
/// open span the running loop level sees. What no span and no render phase covers is unattributed:
/// main-thread work the scheduler has not classified yet.
///
/// An Objective-C exception that AppKit catches and survives unwinds past span ends and loop exits
/// without running them; the app calls ``unwindToTopLevel()`` from `reportException`, where AppKit's
/// own loop goes on at the top level.
///
/// Always on: a turn reads the clock once per observer callout (wake, and each render phase's start
/// and end) and a span twice (the budget's spans reuse its own reads); nothing allocates per turn.
/// The histograms have fixed buckets (``Snapshot/bucketEdges``) and a report folds their percentiles
/// from a ``Snapshot`` off the main thread. A turn over ``stallNanos`` writes `stall.main_turn` to
/// the trace ring: numbers only, no message text (Chrome's `TRACE_EVENT_INSTANT`).
///
/// ```swift
/// let budget = MainFrameBudget(input: SessionInputPending(events: WindowServerInputEvents(input: inputTap)), signposts: true)
/// budget.turns.observe()   // the composition root, once
/// ```
@MainActor
public final class MainTurnMeter {
    /// What a span's time is charged to.
    public enum Span: Sendable {
        /// A task the main-thread scheduler runs.
        case scheduled
        /// AppKit dispatching one event (`sendEvent`).
        case input
    }

    /// A turn longer than this emits `stall.main_turn` (the fixed target: turn p99 <= 4 ms).
    public nonisolated static let stallNanos: UInt64 = 4_000_000
    /// The longest unattributed turns kept for the report.
    public nonisolated static let topCount = 8
    /// The loop and span nesting tracked exactly (one bit per level). A deeper level still counts
    /// its time, charged as the deepest tracked level.
    nonisolated static let maxDepth = 64

    private let uptimeNanos: () -> UInt64
    private let signposts: Bool
    var counters = Snapshot() // read and cleared in MainTurnMeter+Kinds.swift
    private var observers: [MainRunLoopObserver] = []

    // The run-loop levels, innermost last: running loops, and nested loops that exited to the code
    // that ran them (parked) while that session goes on. Per level: the span depth at its entry
    // (the spans it hides), whether it is nested and whether it is parked.
    private var loopDepth = 0
    private var loopSpanBase = [Int](repeating: 0, count: MainTurnMeter.maxDepth)
    private var nestedLoops: UInt64 = 0
    private var parkedLoops: UInt64 = 0
    // The spans the innermost running level hides.
    private var visibleBase = 0
    // Open spans: bit i set when the span at depth i + 1 is input dispatch.
    private var spanDepth = 0
    private var inputSpans: UInt64 = 0
    /// The number of the turn in progress (or of the last one), counted from 1 as each turn begins: work
    /// that must not outlive its turn (a window's layout depth an exception left open) compares it.
    public private(set) var turnNumber: UInt64 = 0
    // The turn in progress.
    private var inTurn = false
    private var turnNested = false
    private var turnStart: UInt64 = 0
    private var mark: UInt64 = 0
    private var scheduled: UInt64 = 0
    private var input: UInt64 = 0
    private var render: UInt64 = 0
    private var rendering = false
    private var renderStart: UInt64 = 0
    private var spansAtRenderStart: UInt64 = 0
    /// The turn in progress: its kinds (``noteTurn(_:)``) and whether it ran a budgeted task (the budget sets it).
    var turnKinds: UInt8 = 0
    var ranBudgetedTask = false
    /// Told when a nested run loop starts running (`true`: its entry, or a parked level's next entry)
    /// and when it stops (`false`: its exit), at `now`. The budget (``MainFrameBudget``) takes that
    /// time out of the task that ran the loop, as Chrome's `RunLevelTracker` suspends a task's work
    /// item while a nested loop it started runs (base/task/sequence_manager/thread_controller.cc,
    /// `OnRunLoopStarted` / `OnRunLoopEnded`). One budget's (it sets it).
    var nestedLoopRunning: (@MainActor (_ running: Bool, _ now: UInt64) -> Void)?

    /// - Parameters:
    ///   - signposts: Whether a turn over ``stallNanos`` emits `stall.main_turn` (the app: true).
    ///   - uptimeNanos: The clock (`CLOCK_UPTIME_RAW` nanoseconds, the budget's); tests move their own.
    public init(signposts: Bool = false, uptimeNanos: @escaping () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }) {
        self.signposts = signposts
        self.uptimeNanos = uptimeNanos
    }

    /// Observes the main run loop in `mode` (the app: the common modes, which hold event tracking and
    /// modal panels): the first observer of entry, after-waiting, before-waiting and exit, and the very
    /// last of before-waiting and exit (``MainRunLoopObserver/init(endingTurn:mode:_:)``), so every
    /// other observer of a phase (the Core Animation commit's and every `.max` one included) runs inside
    /// them. A second call replaces the first.
    public func observe(mode: CFRunLoopMode = .commonModes) {
        observers = []
        let first = MainRunLoopObserver(activities: [.entry, .afterWaiting, .beforeWaiting, .exit], order: .min, mode: mode) { [weak self] activity in
            switch activity {
            case .entry: self?.loopEntered()
            case .afterWaiting: self?.loopWoke()
            case .exit: self?.loopWillExit()
            default: self?.loopWillWait()
            }
        }
        let last = MainRunLoopObserver(endingTurn: [.beforeWaiting, .exit], mode: mode) { [weak self] activity in
            if activity == .exit { self?.loopExited() } else { self?.loopDidRender() }
        }
        observers = [first, last]
    }

    // MARK: Spans

    /// Runs one event's dispatch as a ``Span/input`` span.
    // perf-hot: 100ns main-turn (every event's dispatch)
    public func inputDispatch<T>(_ body: () throws -> T) rethrows -> T {
        try stampedInputDispatch { _ in try body() }
    }

    /// Runs one event's dispatch as a ``Span/input`` span; `body` gets the span's begin stamp (ns of
    /// uptime), the event's dispatch time.
    // perf-hot: 100ns main-turn (every event's dispatch)
    public func stampedInputDispatch<T>(_ body: (_ dispatchedNanos: UInt64) throws -> T) rethrows -> T {
        let now = uptimeNanos()
        beginSpan(.input, at: now)
        defer { endSpan(at: uptimeNanos()) }
        return try body(now)
    }

    /// Opens a span at `now` (the caller's own clock read).
    // perf-hot: 100ns main-turn (every task and event)
    public func beginSpan(_ span: Span, at now: UInt64) {
        credit(now)
        if spanDepth < Self.maxDepth {
            let bit: UInt64 = 1 << UInt64(spanDepth)
            if span == .input { inputSpans |= bit } else { inputSpans &= ~bit }
        }
        spanDepth += 1
    }

    /// Closes the innermost span at `now`. A parked nested level the span entered (the menu or modal
    /// session it ran) ends with it, and a turn of the outer code starts.
    // perf-hot: 100ns main-turn (every task and event)
    public func endSpan(at now: UInt64) {
        guard spanDepth > 0 else { return }
        credit(now)
        spanDepth -= 1
        if parkedLoops != 0 { leaveParkedLevels(at: now, all: false) }
    }

    /// Closes the innermost span, a ``Span/scheduled`` one, at `now`, and counts the task's own time
    /// (its time less its nested tasks') in the task histogram.
    // perf-hot: 100ns main-turn (every task)
    public func endTask(at now: UInt64, ownNanos: UInt64) {
        endSpan(at: now)
        counters.tasks += 1
        counters.maxTaskNanos = max(counters.maxTaskNanos, ownNanos)
        counters.taskBuckets[Snapshot.bucket(ownNanos)] &+= 1
    }

    // MARK: Run-loop activities (the observers call these; tests call them in order)

    /// The run loop was entered (the entry's first observer). A loop entered from inside another or
    /// inside a span is nested: the running turn ends and the inner loop's starts. A parked level
    /// entered again from the same span (the session's next `nextEvent`) runs again in the same turn.
    // perf-hot: 100ns main-turn (every run-loop entry)
    public func loopEntered() {
        let now = uptimeNanos()
        if let level = parkedTop, loopSpanBase[level] == spanDepth {
            credit(now)
            parkedLoops &= ~(1 << UInt64(level))
            visibleBase = spanDepth
            if !inTurn { beginTurn(at: now) }
            nestedLoopRunning?(true, now)
        } else if loopDepth > 0 || spanDepth > 0 {
            endTurn(at: now)
            enterLevel(nested: true)
            beginTurn(at: now)
            // Only a tracked level parks at its exit (loopExited), so only a tracked one is told.
            if loopDepth <= Self.maxDepth { nestedLoopRunning?(true, now) }
        } else {
            enterLevel(nested: false)
            if !inTurn { beginTurn(at: now) }
        }
    }

    /// The run loop woke from waiting (the first observer after waiting).
    // perf-hot: 100ns main-turn (every run-loop wake)
    public func loopWoke() {
        let now = uptimeNanos()
        if parkedLoops != 0 { leaveParkedLevels(at: now, all: true) }
        if !inTurn { beginTurn(at: now) }
    }

    /// The before-waiting phase began (its first observer): the render phase starts.
    // perf-hot: 100ns main-turn (every run-loop turn)
    public func loopWillWait() {
        let now = uptimeNanos()
        if parkedLoops != 0 { leaveParkedLevels(at: now, all: true) }
        beginRender(at: now)
    }

    /// The before-waiting phase ended (its last observer, after every other one): the turn ends.
    // perf-hot: 100ns main-turn (every run-loop turn)
    public func loopDidRender() {
        let now = uptimeNanos()
        if parkedLoops != 0 { leaveParkedLevels(at: now, all: true) }
        endTurn(at: now)
    }

    /// The run loop is exiting (the exit's first observer): Core Animation commits at the exit too,
    /// so a render phase starts.
    // perf-hot: 100ns main-turn (every run-loop exit)
    public func loopWillExit() {
        let now = uptimeNanos()
        if parkedLoops != 0 { leaveParkedLevels(at: now, all: true) }
        beginRender(at: now)
    }

    /// The run loop exited (the exit's last observer); the turn goes on. A top-level exit is AppKit
    /// leaving the loop to dispatch an event. A nested exit returns to the session that ran the loop
    /// (a tracking loop's next event, a menu's action): the level parks until the session enters it
    /// again or ends.
    // perf-hot: 100ns main-turn (every run-loop exit)
    public func loopExited() {
        let now = uptimeNanos()
        if parkedLoops != 0 { leaveParkedLevels(at: now, all: true) }
        guard loopDepth > 0 else { return }
        // Charged at the inner level: the spans the loop hid stay closed up to here.
        credit(now)
        closeRender(at: now)
        let level = loopDepth - 1
        if level < Self.maxDepth, nestedLoops & (1 << UInt64(level)) != 0 {
            parkedLoops |= 1 << UInt64(level)
            nestedLoopRunning?(false, now)
        } else {
            loopDepth -= 1
        }
        refreshVisibleBase()
    }

    /// AppKit caught an Objective-C exception and goes on (`NSApplication.reportException`). The
    /// exception unwound past span ends and loop exits that never ran, so the meter goes back to
    /// the top level: the turn in progress ends and a non-nested one starts.
    public func unwindToTopLevel() {
        let now = uptimeNanos()
        endTurn(at: now)
        for _ in 0..<(nestedLoops & ~parkedLoops).nonzeroBitCount { nestedLoopRunning?(false, now) }
        loopDepth = 0
        nestedLoops = 0
        parkedLoops = 0
        visibleBase = 0
        spanDepth = 0
        inputSpans = 0
        beginTurn(at: now)
    }

    // MARK: Levels

    /// The innermost level, when it is parked and tracked.
    private var parkedTop: Int? {
        guard loopDepth > 0, loopDepth <= Self.maxDepth else { return nil }
        let level = loopDepth - 1
        return parkedLoops & (1 << UInt64(level)) != 0 ? level : nil
    }

    private func enterLevel(nested: Bool) {
        if loopDepth < Self.maxDepth {
            let bit: UInt64 = 1 << UInt64(loopDepth)
            loopSpanBase[loopDepth] = spanDepth
            if nested { nestedLoops |= bit } else { nestedLoops &= ~bit }
            parkedLoops &= ~bit
        }
        loopDepth += 1
        visibleBase = spanDepth
    }

    /// Ends the parked levels at the top: with `all`, every one (an activity of a lower loop came,
    /// so the sessions returned); else those whose entering span closed. The session's turn ends and
    /// one of the outer code starts.
    private func leaveParkedLevels(at now: UInt64, all: Bool) {
        guard let first = parkedTop, all || loopSpanBase[first] > spanDepth else { return }
        endTurn(at: now)
        while let level = parkedTop, all || loopSpanBase[level] > spanDepth {
            let bit: UInt64 = 1 << UInt64(level)
            parkedLoops &= ~bit
            nestedLoops &= ~bit
            loopDepth -= 1
        }
        refreshVisibleBase()
        beginTurn(at: now)
    }

    /// The spans the innermost running level hides (none when every level is parked).
    private func refreshVisibleBase() {
        var level = min(loopDepth, Self.maxDepth) - 1
        while level >= 0, parkedLoops & (1 << UInt64(level)) != 0 { level -= 1 }
        visibleBase = level >= 0 ? loopSpanBase[level] : 0
    }

    // MARK: Turns

    /// Charges the time since the last mark to the innermost span the running loop level sees.
    // perf-hot: 100ns main-turn (every span edge and observer callout)
    private func credit(_ now: UInt64) {
        let elapsed = now > mark ? now - mark : 0
        mark = now
        guard inTurn, spanDepth > visibleBase else { return }
        let top = min(spanDepth, Self.maxDepth) - 1
        if inputSpans & (1 << UInt64(top)) != 0 { input &+= elapsed } else { scheduled &+= elapsed }
    }

    private func beginTurn(at now: UInt64) {
        inTurn = true
        turnNumber &+= 1
        turnNested = nestedLoops != 0
        turnStart = now
        mark = now
        scheduled = 0
        input = 0
        render = 0
        rendering = false
        (turnKinds, ranBudgetedTask) = (0, false)
    }

    private func beginRender(at now: UInt64) {
        if !inTurn { beginTurn(at: now) }
        credit(now)
        guard !rendering else { return }
        rendering = true
        renderStart = now
        spansAtRenderStart = scheduled &+ input
    }

    /// Ends a render phase at `now` (the caller charged the spans up to `now`). A span inside the
    /// phase (an observer running a task) keeps its own time.
    private func closeRender(at now: UInt64) {
        guard rendering else { return }
        rendering = false
        let phase = now > renderStart ? now - renderStart : 0
        let inSpans = (scheduled &+ input) &- spansAtRenderStart
        render &+= phase > inSpans ? phase - inSpans : 0
    }

    private func endTurn(at now: UInt64) {
        guard inTurn else { return }
        credit(now)
        closeRender(at: now)
        inTurn = false
        let total = now > turnStart ? now - turnStart : 0
        let attributed = scheduled &+ input &+ render
        record(TopTurn(turnNanos: total, unattributedNanos: total > attributed ? total - attributed : 0, scheduledNanos: scheduled,
                       inputNanos: input, renderNanos: render, endNanos: now, nested: turnNested))
        if turnKinds != 0 { recordKinds(turnNanos: total) }
    }

    // perf-hot: 100ns main-turn (every run-loop turn)
    private func record(_ turn: TopTurn) {
        counters.turns += 1
        if turn.nested { counters.nestedTurns += 1 }
        counters.busyNanos &+= turn.turnNanos
        counters.scheduledNanos &+= turn.scheduledNanos
        counters.inputNanos &+= turn.inputNanos
        counters.renderNanos &+= turn.renderNanos
        counters.unattributedNanos &+= turn.unattributedNanos
        counters.maxTurnNanos = max(counters.maxTurnNanos, turn.turnNanos)
        counters.turnBuckets[Snapshot.bucket(turn.turnNanos)] &+= 1
        if turn.turnNanos > Self.stallNanos {
            counters.turnsOverStall += 1
            if signposts { Signposter.event(.stallMainTurn, arg0: turn.ringArg0, arg1: turn.ringArg1) }
        }
        guard turn.unattributedNanos > 0 else { return }
        var smallest = 0
        for index in 1..<counters.topUnattributed.count
        where counters.topUnattributed[index].unattributedNanos < counters.topUnattributed[smallest].unattributedNanos {
            smallest = index
        }
        if turn.unattributedNanos > counters.topUnattributed[smallest].unattributedNanos { counters.topUnattributed[smallest] = turn }
    }
}
