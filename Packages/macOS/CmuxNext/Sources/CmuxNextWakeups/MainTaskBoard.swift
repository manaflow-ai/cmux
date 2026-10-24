import CmuxNextCompat

/// What the main-thread scheduler runs right now, readable from any thread: the stall watchdog
/// reads it from its own thread while the main thread is stuck, so a stall record names the
/// culprit task, its class and its budget next to the stack (plans/cmux-next/main-thread-budget.md).
///
/// The main thread writes it at every scheduled task's and action span's start and end with
/// relaxed and releasing atomic stores (no lock; owner names are interned once per owner). What it
/// publishes is the newest entry still open: tasks end in LIFO order, but an action span ends at
/// the commit after it, so spans end in begin order (FIFO) and may outlive the task they began in.
/// Ending one entry removes exactly that entry, and the board publishes whichever entry is newest
/// among those still open, never a copy taken when the ended one began. Injected input
/// that waits for the main thread (`debug.key` requests) is counted here too, because it is
/// enqueued off the main thread: ``MainFrameBudget`` makes every budgeted class yield while the
/// count is above zero.
///
/// ```swift
/// let board = scheduler.budget.board
/// if let task = board.running { print(task.owner, task.workClass) }
/// ```
public final class MainTaskBoard: Sendable {
    /// One running task as the watchdog sees it.
    public struct Task: Sendable, Equatable {
        /// The task's priority class.
        public var workClass: MainWorkClass
        /// The batch owner or control method that scheduled it.
        public var owner: String
        /// Increases with every task the scheduler starts; tells two tasks of one owner apart.
        public var sequence: UInt32
        /// `CLOCK_UPTIME_RAW` nanoseconds when it started.
        public var startNanos: UInt64
        /// Its class's per-frame budget in nanoseconds (0: unbudgeted).
        public var budgetNanos: UInt64
    }

    /// Packed `class << 56 | owner << 32 | sequence`; 0 while no task runs.
    private let current = Atomic<UInt64>(0)
    private let startNanos = Atomic<UInt64>(0)
    private let budgetNanos = Atomic<UInt64>(0)
    private let pendingInput = Atomic<Int>(0)
    /// Owner names by index (index 0 is reserved for "no task").
    private let owners = Mutex<(names: [String], indices: [String: UInt32])>(([""], [:]))
    /// Called on the main thread at every task and span start once installed (the watchdog's wake,
    /// DEBUG and bench builds only), so it can sample work that runs past its budget. Set once
    /// (``setTaskStartHook(_:)``); `hookState` says whether it is, so a board with no watchdog takes
    /// no lock at all. The lock is held only to copy the closure: it is contended only while the
    /// one setter runs, at launch.
    private let taskStartHook = Mutex<(@Sendable () -> Void)?>(nil)
    /// 0: no hook, 1: being set, 2: set (readable).
    private let hookState = Atomic<Int>(0)
    private let spanSequence = Atomic<UInt32>(0)
    /// The open entries (scheduled tasks and action spans), oldest first; the last is published.
    // Main thread only: every writer (begin, end, beginSpan, endSpan) runs on the main thread by
    // contract, and no other thread reads it (the watchdog reads only the atomics above).
    private nonisolated(unsafe) var open: [Entry] = []

    /// One open task or span as published.
    private struct Entry {
        let packed: UInt64
        let startNanos: UInt64
        let budgetNanos: UInt64
    }
    /// Receives each finished task that ran past its budget, on the main thread.
    private let overBudgetSink = Mutex<(@Sendable (Task, _ durationNanos: UInt64) -> Void)?>(nil)

    public init() {}

    /// The index `name` is published under (interned on first use).
    func ownerIndex(_ name: String) -> UInt32 {
        owners.withLock { owners in
            if let index = owners.indices[name] { return index }
            let index = UInt32(owners.names.count) & 0x00FF_FFFF
            owners.names.append(name)
            owners.indices[name] = index
            return index
        }
    }

    /// Publishes a task start (main thread) as the newest open entry.
    ///
    /// - Returns: The task's packed identity, which ``end(_:task:durationNanos:overBudget:)`` takes.
    @discardableResult
    func begin(_ workClass: MainWorkClass, owner: UInt32, sequence: UInt32, startNanos start: UInt64, budgetNanos budget: UInt64) -> UInt64 {
        let packed = UInt64(UInt8(workClass.rawValue)) << 56 | UInt64(owner & 0x00FF_FFFF) << 32 | UInt64(sequence)
        open.append(Entry(packed: packed, startNanos: start, budgetNanos: budget))
        publish(packed, startNanos: start, budgetNanos: budget)
        notifyStart()
        return packed
    }

    /// Ends the open task `packed` (main thread) and publishes the newest entry still open; reports
    /// the task when it ran past its budget.
    func end(_ packed: UInt64, task: @autoclosure () -> Task, durationNanos: UInt64, overBudget: Bool) {
        close(packed)
        guard overBudget, let sink = overBudgetSink.withLock({ $0 }) else { return }
        sink(task(), durationNanos)
    }

    private func publish(_ packed: UInt64, startNanos start: UInt64, budgetNanos budget: UInt64) {
        startNanos.store(start, ordering: .relaxed)
        budgetNanos.store(budget, ordering: .relaxed)
        current.store(packed, ordering: .releasing)
    }

    private func notifyStart() {
        if hookState.load(ordering: .acquiring) == 2 { taskStartHook.withLock { $0 }?() }
    }

    /// Removes the open entry `packed` (searched newest first: tasks end LIFO, so a task is found at
    /// once). When it was the published one, the newest entry still open is published instead (or
    /// nothing), and the watchdog is woken so it times that entry against its own budget; when a
    /// newer entry is open, what is published does not change. An entry already ended is ignored.
    private func close(_ packed: UInt64) {
        guard let index = open.lastIndex(where: { $0.packed == packed }) else { return }
        open.remove(at: index)
        guard index == open.count else { return }
        guard let top = open.last else {
            publish(0, startNanos: 0, budgetNanos: 0)
            return
        }
        publish(top.packed, startNanos: top.startNanos, budgetNanos: top.budgetNanos)
        notifyStart()
    }

    /// The task running now, or nil between tasks. Safe on any thread; the owner name is looked
    /// up under a lock the main thread holds only while interning a new owner.
    public var running: Task? {
        let packed = current.load(ordering: .acquiring)
        guard packed != 0 else { return nil }
        let start = startNanos.load(ordering: .relaxed)
        let budget = budgetNanos.load(ordering: .relaxed)
        // A newer task replaced it between the loads: report the newer one's identity only.
        guard current.load(ordering: .acquiring) == packed else { return nil }
        return Self.unpack(packed, start: start, budget: budget, name: name(of:))
    }

    /// The packed identity of the running task (0 when none), for a reader that must not take a
    /// lock (the watchdog while the main thread is suspended); resolve it later with ``task(packed:)``.
    public var runningPacked: (packed: UInt64, startNanos: UInt64, budgetNanos: UInt64) {
        (current.load(ordering: .acquiring), startNanos.load(ordering: .relaxed), budgetNanos.load(ordering: .relaxed))
    }

    /// Resolves a value read with ``runningPacked``.
    public func task(packed: UInt64, startNanos: UInt64, budgetNanos: UInt64) -> Task? {
        guard packed != 0 else { return nil }
        return Self.unpack(packed, start: startNanos, budget: budgetNanos, name: name(of:))
    }

    private func name(of index: UInt32) -> String {
        owners.withLock { owners in Int(index) < owners.names.count ? owners.names[Int(index)] : "?" }
    }

    private static func unpack(_ packed: UInt64, start: UInt64, budget: UInt64, name: (UInt32) -> String) -> Task? {
        guard let workClass = MainWorkClass(rawValue: Int(packed >> 56)) else { return nil }
        return Task(workClass: workClass, owner: name(UInt32(truncatingIfNeeded: packed >> 32) & 0x00FF_FFFF),
                    sequence: UInt32(truncatingIfNeeded: packed), startNanos: start, budgetNanos: budget)
    }

    // MARK: Injected input

    /// Injected input requests waiting for the main thread.
    public var pendingInputCount: Int { pendingInput.load(ordering: .acquiring) }

    /// One injected input request was queued (any thread).
    public func inputQueued() { pendingInput.add(1, ordering: .releasing) }

    /// One injected input request ran or was dropped (any thread).
    public func inputDone() { pendingInput.subtract(1, ordering: .releasing) }

    // MARK: Watchdog hooks

    /// Installs (or removes, with nil) the call made at every task start. The watchdog installs
    /// one in DEBUG and bench builds to wake its thread, so it samples a task that runs past its
    /// budget; it must return at once (a semaphore signal).
    /// Set once: a later call is ignored (the one watchdog of a board installs it at launch).
    public func setTaskStartHook(_ hook: @escaping @Sendable () -> Void) {
        guard hookState.compareExchange(expected: 0, desired: 1, ordering: .acquiringAndReleasing).exchanged else { return }
        taskStartHook.withLock { $0 = hook }
        hookState.store(2, ordering: .releasing)
    }

    /// Whether a task start hook is installed (the watchdog samples over-budget tasks only then).
    public var hasTaskStartHook: Bool { hookState.load(ordering: .acquiring) == 2 }

    // MARK: Action spans

    /// What ``endSpan(_:nowNanos:)`` needs: the span's identity, start and budget.
    public struct SpanToken: Sendable {
        let packed: UInt64
        let startNanos: UInt64
        let budgetNanos: UInt64
    }

    /// The index `name` is published under: intern an action id once, off the action's path, then
    /// pass the index to ``beginSpan(_:owner:budgetNanos:startNanos:)`` (which takes no lock).
    public func internOwner(_ name: String) -> UInt32 { ownerIndex(name) }

    /// Publishes a person's action (input dispatch to its commit) as the running work, with a
    /// caller-given budget: the watchdog samples it once it runs past that budget and names it in
    /// a stall. Atomics and one append to the open list (no allocation once it has grown to the
    /// deepest nesting seen); main thread. A span is the newest open entry until a newer task or
    /// span begins: a span begun inside a scheduled task (an action a control request runs) covers
    /// that task, and stays published after the task ends, through the commit it is timed to.
    ///
    /// - Parameters:
    ///   - workClass: Its class (``MainWorkClass/input`` for a person's action).
    ///   - owner: ``internOwner(_:)`` of the action id.
    ///   - budgetNanos: Its budget (an action: 10 ms to its committed frame).
    ///   - startNanos: When it began (`CLOCK_UPTIME_RAW` nanoseconds; the input event's time for a key).
    /// - Returns: The token ``endSpan(_:nowNanos:)`` takes.
    public func beginSpan(_ workClass: MainWorkClass, owner: UInt32, budgetNanos: UInt64, startNanos start: UInt64) -> SpanToken {
        let sequence = spanSequence.add(1, ordering: .relaxed).newValue | 0x8000_0000
        let packed = begin(workClass, owner: owner, sequence: sequence, startNanos: start, budgetNanos: budgetNanos)
        return SpanToken(packed: packed, startNanos: start, budgetNanos: budgetNanos)
    }

    /// Ends the span `token` began: removes exactly that span, and the board publishes the newest
    /// entry still open (a task or a span begun after it, or nothing), whatever order the spans end
    /// in. A span that ran past its budget is reported to the over-budget sink (the watchdog's
    /// `over_budget` record, with the stack it sampled). Atomics only unless it ran over.
    ///
    /// - Parameter nowNanos: Its end (`CLOCK_UPTIME_RAW` nanoseconds; an action's commit end).
    public func endSpan(_ token: SpanToken, nowNanos: UInt64) {
        close(token.packed)
        let elapsed = nowNanos &- token.startNanos
        guard token.budgetNanos > 0, elapsed > token.budgetNanos, let sink = overBudgetSink.withLock({ $0 }),
              let task = task(packed: token.packed, startNanos: token.startNanos, budgetNanos: token.budgetNanos) else { return }
        sink(task, elapsed)
    }

    /// Installs (or removes) the receiver of finished over-budget tasks (main thread, must return at once).
    public func setOverBudgetSink(_ sink: (@Sendable (Task, _ durationNanos: UInt64) -> Void)?) {
        overBudgetSink.withLock { $0 = sink }
    }
}
