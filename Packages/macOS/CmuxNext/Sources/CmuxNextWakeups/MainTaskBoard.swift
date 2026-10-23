import CmuxNextCompat

/// What the main-thread scheduler runs right now, readable from any thread: the stall watchdog
/// reads it from its own thread while the main thread is stuck, so a stall record names the
/// culprit task, its class and its budget next to the stack (plans/cmux-next/main-thread-budget.md).
///
/// The main thread writes it at every scheduled task's start and end with relaxed and releasing
/// atomic stores (no lock, no allocation); owner names are interned once per owner. Injected input
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
    /// Called on the main thread at every task start while installed (the watchdog's wake, DEBUG
    /// and bench builds only), so it can sample a task that runs past its budget.
    private let taskStartHook = Mutex<(@Sendable () -> Void)?>(nil)
    private let hookInstalled = Atomic<Bool>(false)
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

    /// Publishes a task start (main thread).
    func begin(_ workClass: MainWorkClass, owner: UInt32, sequence: UInt32, startNanos start: UInt64, budgetNanos budget: UInt64,
               notify: Bool = true) {
        startNanos.store(start, ordering: .relaxed)
        budgetNanos.store(budget, ordering: .relaxed)
        let packed = UInt64(UInt8(workClass.rawValue)) << 56 | UInt64(owner & 0x00FF_FFFF) << 32 | UInt64(sequence)
        current.store(packed, ordering: .releasing)
        if notify, hookInstalled.load(ordering: .relaxed) { taskStartHook.withLock { $0 }?() }
    }

    /// Publishes the end of the running task (main thread); reports it when it ran past its budget.
    func end(_ task: @autoclosure () -> Task, durationNanos: UInt64, overBudget: Bool) {
        current.store(0, ordering: .releasing)
        guard overBudget, let sink = overBudgetSink.withLock({ $0 }) else { return }
        sink(task(), durationNanos)
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
    public func setTaskStartHook(_ hook: (@Sendable () -> Void)?) {
        taskStartHook.withLock { $0 = hook }
        hookInstalled.store(hook != nil, ordering: .releasing)
    }

    /// Whether a task start hook is installed (the watchdog samples over-budget tasks only then).
    public var hasTaskStartHook: Bool { hookInstalled.load(ordering: .acquiring) }

    /// Installs (or removes) the receiver of finished over-budget tasks (main thread, must return at once).
    public func setOverBudgetSink(_ sink: (@Sendable (Task, _ durationNanos: UInt64) -> Void)?) {
        overBudgetSink.withLock { $0 = sink }
    }
}
