public import CoreFoundation
import CmuxNextCompat
import CmuxNextSignposts
import Darwin

/// Times every busy turn of the main run loop and splits it into scheduled work, render, input
/// dispatch and unattributed time (plans/cmux-next/chrome-parity/p06-scheduler.md, "Attribution").
///
/// A turn starts when the run loop wakes (after-waiting) and ends at the end of its before-waiting
/// phase (layout, display and the Core Animation commit), or at a nested loop's boundary. AppKit's
/// own loop leaves the run loop to dispatch each event (`nextEvent`, then `sendEvent`) and enters it
/// again: that exit and entry stay inside one turn, and the exit's commit counts as render.
///
/// Nested run loops (menu tracking, modal sessions, live resize, drag loops) are Chromium's run
/// levels (base/task/sequence_manager/thread_controller.h, `RunLevelTracker`; the observers are
/// base/message_loop/message_pump_apple.mm's `EnterExitObserver`): a loop entered while a span is
/// open or from inside another loop is nested, and only the innermost level's turn is attributed.
/// Its entry ends the turn that was running and starts the inner one; its exit ends the inner turn
/// and starts a new one of the outer code. The spans open when it started (the `sendEvent` that
/// runs a menu) are closed for the inner loop's time and resume after it, so no time is counted twice.
///
/// Attribution comes from spans: ``MainFrameBudget/run(_:owner:_:)`` opens a ``Span/scheduled`` span
/// per task, and the app's `sendEvent` runs inside ``inputDispatch(_:)``. Time goes to the innermost
/// open span. What no span and no render phase covers is unattributed: main-thread work the
/// scheduler has not classified yet.
///
/// Always on: a turn reads the clock once per observer callout (wake, and each render phase's start
/// and end) and a span twice (the budget's spans reuse its own reads); nothing allocates per turn.
/// The histograms have fixed buckets (``Snapshot/bucketEdges``) and a report folds their
/// percentiles from a ``Snapshot``. A turn over ``stallNanos`` emits `stall.main_turn`.
///
/// ```swift
/// let budget = MainFrameBudget(input: SessionInputPending(), signposts: true)
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
    private var counters = Snapshot()
    private var observers: [MainRunLoopObserver] = []

    // The run loop's depth; per level, the span depth when it was entered (the spans it hides) and
    // whether it was entered nested.
    private var loopDepth = 0
    private var loopSpanBase = [Int](repeating: 0, count: MainTurnMeter.maxDepth)
    private var nestedLoops: UInt64 = 0
    // Open spans: bit i set when the span at depth i + 1 is input dispatch.
    private var spanDepth = 0
    private var inputSpans: UInt64 = 0
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

    /// - Parameters:
    ///   - signposts: Whether a turn over ``stallNanos`` emits `stall.main_turn` (the app: true).
    ///   - uptimeNanos: The clock (`CLOCK_UPTIME_RAW` nanoseconds, the budget's); tests move their own.
    public init(signposts: Bool = false, uptimeNanos: @escaping () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }) {
        self.signposts = signposts
        self.uptimeNanos = uptimeNanos
    }

    /// Observes the main run loop in `mode` (the app: the common modes, which hold event tracking and
    /// modal panels): the first observer of entry, after-waiting, before-waiting and exit, and the last
    /// of before-waiting and exit, so every other observer of a phase (the Core Animation commit's
    /// included) runs inside them. A second call replaces the first.
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
        let last = MainRunLoopObserver(activities: [.beforeWaiting, .exit], order: .max, mode: mode) { [weak self] activity in
            if activity == .exit { self?.loopExited() } else { self?.loopDidRender() }
        }
        observers = [first, last]
    }

    // MARK: Spans

    /// Runs one event's dispatch as a ``Span/input`` span.
    public func inputDispatch<T>(_ body: () throws -> T) rethrows -> T {
        beginSpan(.input, at: uptimeNanos())
        defer { endSpan(at: uptimeNanos()) }
        return try body()
    }

    /// Opens a span at `now` (the caller's own clock read).
    public func beginSpan(_ span: Span, at now: UInt64) {
        credit(now)
        if spanDepth < Self.maxDepth {
            let bit: UInt64 = 1 << UInt64(spanDepth)
            if span == .input { inputSpans |= bit } else { inputSpans &= ~bit }
        }
        spanDepth += 1
    }

    /// Closes the innermost span at `now`.
    public func endSpan(at now: UInt64) {
        guard spanDepth > 0 else { return }
        credit(now)
        spanDepth -= 1
    }

    /// Closes the innermost span, a ``Span/scheduled`` one, at `now`, and counts the task's own time
    /// (its time less its nested tasks') in the task histogram.
    public func endTask(at now: UInt64, ownNanos: UInt64) {
        endSpan(at: now)
        counters.tasks += 1
        counters.maxTaskNanos = max(counters.maxTaskNanos, ownNanos)
        counters.taskBuckets[Snapshot.bucket(ownNanos)] &+= 1
    }

    // MARK: Run-loop activities (the observers call these; tests call them in order)

    /// The run loop was entered (the entry's first observer). A loop entered from inside another or
    /// inside a span is nested: the running turn ends and the inner loop's starts.
    public func loopEntered() {
        let nested = loopDepth > 0 || spanDepth > 0
        if nested {
            let now = uptimeNanos()
            endTurn(at: now)
            enterLevel(nested: true)
            beginTurn(at: now)
        } else {
            enterLevel(nested: false)
            if !inTurn { beginTurn(at: uptimeNanos()) }
        }
    }

    /// The run loop woke from waiting (the first observer after waiting).
    public func loopWoke() {
        if !inTurn { beginTurn(at: uptimeNanos()) }
    }

    /// The before-waiting phase began (its first observer): the render phase starts.
    public func loopWillWait() {
        beginRender(at: uptimeNanos())
    }

    /// The before-waiting phase ended (its last observer): the turn ends.
    public func loopDidRender() {
        endTurn(at: uptimeNanos())
    }

    /// The run loop is exiting (the exit's first observer): Core Animation commits at the exit too,
    /// so a render phase starts.
    public func loopWillExit() {
        beginRender(at: uptimeNanos())
    }

    /// The run loop exited (the exit's last observer). A nested loop's exit ends its turn and starts
    /// one of the outer code, whose spans resume; a top-level exit (AppKit leaving the loop to
    /// dispatch an event) keeps the turn.
    public func loopExited() {
        guard loopDepth > 0 else { return }
        let now = uptimeNanos()
        // Charged at the inner level: the spans the loop hid stay closed up to here.
        credit(now)
        closeRender(at: now)
        loopDepth -= 1
        guard loopDepth < Self.maxDepth else { return }
        let bit: UInt64 = 1 << UInt64(loopDepth)
        guard nestedLoops & bit != 0 else { return }
        nestedLoops &= ~bit
        endTurn(at: now)
        beginTurn(at: now)
    }

    // MARK: Reading

    /// The counters, with the longest unattributed turns sorted longest first.
    public func snapshot() -> Snapshot {
        var copy = counters
        copy.topUnattributed = copy.topUnattributed.filter { $0.unattributedNanos > 0 }.sorted { $0.unattributedNanos > $1.unattributedNanos }
        return copy
    }

    /// Clears the counters (`debug.main_budget reset`); the turn in progress is kept.
    public func reset() {
        counters = Snapshot()
    }

    // MARK: Turns

    private func enterLevel(nested: Bool) {
        if loopDepth < Self.maxDepth {
            let bit: UInt64 = 1 << UInt64(loopDepth)
            loopSpanBase[loopDepth] = spanDepth
            if nested { nestedLoops |= bit } else { nestedLoops &= ~bit }
        }
        loopDepth += 1
    }

    /// The spans the innermost loop level hides: those open when it was entered.
    private var visibleSpanBase: Int {
        loopDepth == 0 ? 0 : loopSpanBase[min(loopDepth, Self.maxDepth) - 1]
    }

    /// Charges the time since the last mark to the innermost span the current loop level sees.
    private func credit(_ now: UInt64) {
        let elapsed = now > mark ? now - mark : 0
        mark = now
        guard inTurn, spanDepth > visibleSpanBase else { return }
        let top = min(spanDepth, Self.maxDepth) - 1
        if inputSpans & (1 << UInt64(top)) != 0 { input &+= elapsed } else { scheduled &+= elapsed }
    }

    private func beginTurn(at now: UInt64) {
        inTurn = true
        turnNested = nestedLoops != 0
        turnStart = now
        mark = now
        scheduled = 0
        input = 0
        render = 0
        rendering = false
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
    }

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
            if signposts { Signposter.stall.event(.stallMainTurn, turn.message) }
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
