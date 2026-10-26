import CmuxNextCompat

/// What the main-thread scheduler runs right now, readable from any thread: the stall watchdog
/// reads it from its own thread while the main thread is stuck, so a stall record names the
/// culprit task, its class and its budget next to the stack (plans/cmux-next/main-thread-budget.md).
///
/// The main thread writes it at every scheduled task's start and end with relaxed and releasing
/// atomic stores (no lock, no allocation); owner names are interned once per owner, off the task's
/// path (``owner(_:)``, ``MainTaskOwner``). Injected input
/// that waits for the main thread (`debug.key` requests) is counted here too, because it is
/// enqueued off the main thread: ``MainFrameBudget`` makes every budgeted class yield while the
/// count is above zero.
///
/// Every finished task also goes to the board's ``ledger`` (one fixed slot, no lock): its owner,
/// class, run time and, for a posted task (``MainFrameBudget/run(_:owner:posted:_:)``), its wait,
/// posting location and node state. ``ownerSnapshot()`` reads the per-owner percentiles.
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
        /// Where it was posted (``MainWorkScheduler/post(_:owner:file:line:_:)``); nil for a batch
        /// tick, an action span, or an outer task while a posted task nested in it ran.
        public var postedFrom: PostedFrom?
    }

    /// The source location a task was posted from: Chrome's `posted_from` (`FROM_HERE`,
    /// base/location.h), built from the ``MainPostSite`` only when a reader asks.
    public struct PostedFrom: Sendable, Equatable, CustomStringConvertible {
        /// The posting file's `#fileID` (`Module/File.swift`).
        public var file: String
        /// The posting line.
        public var line: UInt

        public init(file: String, line: UInt) {
            self.file = file
            self.line = line
        }

        public var description: String { "\(file):\(line)" }
    }

    /// Packed `class << 56 | owner << 32 | sequence`; 0 while no task runs.
    private let current = Atomic<UInt64>(0)
    private let startNanos = Atomic<UInt64>(0)
    private let budgetNanos = Atomic<UInt64>(0)
    private let pendingInput = Atomic<Int>(0)
    /// The posting site of the task whose packed identity is in ``postedFor`` (0: none): the
    /// `#fileID` literal's address, its length `<< 32 | line`. A site is the running task's only
    /// while `postedFor == current`, so a later task never shows an earlier task's site.
    private let postedFor = Atomic<UInt64>(0)
    private let postedFile = Atomic<UInt>(0)
    private let postedLengthLine = Atomic<UInt64>(0)
    /// Owner names by index (index 0 is reserved for "no task").
    private let owners = Mutex<(names: [String], indices: [String: UInt32])>(([""], [:]))
    /// Called on the main thread at every task and span start once installed (the watchdog's wake,
    /// only in the explicit task-diagnostics mode: it costs a cross-thread wake per task, so bench
    /// numbers are taken without it), so it can sample work that runs past its budget. Set once
    /// (``setTaskStartHook(_:)``); `hookState` says whether it is, so a board with no watchdog takes
    /// no lock at all. The lock is held only to copy the closure: it is contended only while the
    /// one setter runs, at launch.
    private let taskStartHook = Mutex<(@Sendable () -> Void)?>(nil)
    /// 0: no hook, 1: being set, 2: set (readable).
    private let hookState = Atomic<Int>(0)
    private let spanSequence = Atomic<UInt32>(0)
    /// Receives each finished task that ran past its budget, on the main thread.
    private let overBudgetSink = Mutex<(@Sendable (Task, _ durationNanos: UInt64) -> Void)?>(nil)
    /// Per-owner wait and run time of the finished tasks.
    public let ledger: MainOwnerLedger

    /// - Parameter ledger: Where finished tasks are recorded (default: one that folds in the background).
    public init(ledger: MainOwnerLedger = MainOwnerLedger()) {
        self.ledger = ledger
    }

    /// `name` interned on this board (takes the owners lock: call it when the queue or method is
    /// built, or off the main thread, never per task on the main thread).
    public func owner(_ name: String) -> MainTaskOwner {
        MainTaskOwner(name: name, index: ownerIndex(name))
    }

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

    /// Per owner and class, the wait and run percentiles, node states and posting locations of the
    /// finished tasks. It folds what the main thread wrote since the last fold on the caller's
    /// thread, under the ledger's lock: call it off the main thread (`debug.main_budget` does).
    public func ownerSnapshot() -> MainOwnerLedger.Snapshot {
        ledger.fold()
        return ledger.snapshot(name: name(of:))
    }

    /// Publishes a task start (main thread).
    func begin(_ workClass: MainWorkClass, owner: UInt32, sequence: UInt32, startNanos start: UInt64, budgetNanos budget: UInt64,
               notify: Bool = true) {
        startNanos.store(start, ordering: .relaxed)
        budgetNanos.store(budget, ordering: .relaxed)
        let packed = UInt64(UInt8(workClass.rawValue)) << 56 | UInt64(owner & 0x00FF_FFFF) << 32 | UInt64(sequence)
        current.store(packed, ordering: .releasing)
        if notify, hookState.load(ordering: .acquiring) == 2 { taskStartHook.withLock { $0 }?() }
    }

    /// Publishes the end of the running task (main thread); reports it when it ran past its budget,
    /// with the site it was posted from.
    func end(_ task: @autoclosure () -> Task, durationNanos: UInt64, overBudget: Bool) {
        let ending = current.load(ordering: .relaxed)
        current.store(0, ordering: .releasing)
        guard overBudget, let sink = overBudgetSink.withLock({ $0 }) else { return }
        var finished = task()
        if ending != 0, postedFor.load(ordering: .relaxed) == ending {
            finished.postedFrom = Self.postedFrom(file: postedFile.load(ordering: .relaxed),
                                                  lengthLine: postedLengthLine.load(ordering: .relaxed))
        }
        sink(finished, durationNanos)
    }

    /// Records where the running task was posted (main thread, inside the task, right after
    /// ``MainFrameBudget/run(_:owner:posted:_:)`` published it). Atomic stores only, no allocation: the
    /// site's `#fileID` is a static literal, kept by address.
    func notePostedFrom(_ site: MainPostSite) {
        let packed = current.load(ordering: .relaxed)
        guard packed != 0 else { return }
        let file = site.file
        let address = file.hasPointerRepresentation ? UInt(bitPattern: file.utf8Start) : 0
        let length = file.hasPointerRepresentation ? UInt64(UInt32(truncatingIfNeeded: file.utf8CodeUnitCount)) : 0
        // Releasing stores: a reader that sees any of these also sees the task they belong to in
        // `current`, so its identity check rejects a site written for a newer task.
        postedFile.store(address, ordering: .releasing)
        postedLengthLine.store(length << 32 | UInt64(UInt32(truncatingIfNeeded: site.line)), ordering: .releasing)
        postedFor.store(packed, ordering: .releasing)
    }

    /// The site a raw record names (nil when it holds none).
    private static func postedFrom(file: UInt, lengthLine: UInt64) -> PostedFrom? {
        guard let start = UnsafePointer<UInt8>(bitPattern: file) else { return nil }
        let name = String(decoding: UnsafeBufferPointer(start: start, count: Int(lengthLine >> 32)), as: UTF8.self)
        return PostedFrom(file: name, line: UInt(UInt32(truncatingIfNeeded: lengthLine)))
    }

    /// The task running now, or nil between tasks. Safe on any thread; the owner name is looked
    /// up under a lock the main thread holds only while interning a new owner.
    public var running: Task? {
        let packed = current.load(ordering: .acquiring)
        guard packed != 0 else { return nil }
        let start = startNanos.load(ordering: .relaxed)
        let budget = budgetNanos.load(ordering: .relaxed)
        let siteOwner = postedFor.load(ordering: .acquiring)
        let file = postedFile.load(ordering: .acquiring)
        let lengthLine = postedLengthLine.load(ordering: .acquiring)
        // A newer task replaced it between the loads: report the newer one's identity only.
        guard current.load(ordering: .acquiring) == packed else { return nil }
        var task = Self.unpack(packed, start: start, budget: budget, name: name(of:))
        if siteOwner == packed { task?.postedFrom = Self.postedFrom(file: file, lengthLine: lengthLine) }
        return task
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

    /// Installs the call made at every task start. The watchdog installs one in the explicit
    /// task-diagnostics mode to wake its thread, so it samples a task that runs past its budget;
    /// it must return at once (the watchdog triggers a kqueue user event).
    /// Set once: a later call is ignored (the one watchdog of a board installs it at launch).
    public func setTaskStartHook(_ hook: @escaping @Sendable () -> Void) {
        guard hookState.compareExchange(expected: 0, desired: 1, ordering: .acquiringAndReleasing).exchanged else { return }
        taskStartHook.withLock { $0 = hook }
        hookState.store(2, ordering: .releasing)
    }

    /// Whether a task start hook is installed (the watchdog samples over-budget tasks only then).
    public var hasTaskStartHook: Bool { hookState.load(ordering: .acquiring) == 2 }

    // MARK: Action spans

    /// What ``endSpan(_:nowNanos:)`` needs: the span itself and the task it covered.
    public struct SpanToken: Sendable {
        let packed: UInt64
        let startNanos: UInt64
        let budgetNanos: UInt64
        let previous: (packed: UInt64, startNanos: UInt64, budgetNanos: UInt64)
    }

    /// The index `name` is published under: intern an action id once, off the action's path, then
    /// pass the index to ``beginSpan(_:owner:budgetNanos:startNanos:)`` (which takes no lock).
    public func internOwner(_ name: String) -> UInt32 { ownerIndex(name) }

    /// Publishes a person's action (input dispatch to its commit) as the running work, with a
    /// caller-given budget: the watchdog samples it once it runs past that budget and names it in
    /// a stall. Atomics only, no allocation; main thread. A span inside a scheduled task (an action
    /// a control request runs) covers it until ``endSpan(_:nowNanos:)`` puts it back.
    ///
    /// - Parameters:
    ///   - workClass: Its class (``MainWorkClass/input`` for a person's action).
    ///   - owner: ``internOwner(_:)`` of the action id.
    ///   - budgetNanos: Its budget (an action: 10 ms to its committed frame).
    ///   - startNanos: When it began (`CLOCK_UPTIME_RAW` nanoseconds; the input event's time for a key).
    /// - Returns: The token ``endSpan(_:nowNanos:)`` takes.
    public func beginSpan(_ workClass: MainWorkClass, owner: UInt32, budgetNanos: UInt64, startNanos start: UInt64) -> SpanToken {
        let previous = runningPacked
        let sequence = spanSequence.add(1, ordering: .relaxed).newValue | 0x8000_0000
        begin(workClass, owner: owner, sequence: sequence, startNanos: start, budgetNanos: budgetNanos)
        let packed = UInt64(UInt8(workClass.rawValue)) << 56 | UInt64(owner & 0x00FF_FFFF) << 32 | UInt64(sequence)
        return SpanToken(packed: packed, startNanos: start, budgetNanos: budgetNanos, previous: previous)
    }

    /// Ends the span `token` began and puts back the work it covered; a span that ran past its
    /// budget is reported to the over-budget sink (the watchdog's `over_budget` record, with the
    /// stack it sampled). Atomics only unless it ran over.
    ///
    /// - Parameter nowNanos: Its end (`CLOCK_UPTIME_RAW` nanoseconds; an action's commit end).
    public func endSpan(_ token: SpanToken, nowNanos: UInt64) {
        let previous = token.previous
        startNanos.store(previous.startNanos, ordering: .relaxed)
        budgetNanos.store(previous.budgetNanos, ordering: .relaxed)
        current.store(previous.packed, ordering: .releasing)
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
