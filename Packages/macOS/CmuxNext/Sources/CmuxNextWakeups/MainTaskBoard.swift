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
/// Each running task is also a hang scope with its class's deadline (``hangScopeNanos(_:)``, Chrome's
/// `WatchHangsInScope`, base/threading/hang_watcher.h): the watchdog reads ``hangScope`` and reports a
/// task still running past it, with its owner, class, location and stack, without crashing. A nested
/// run loop (a menu, a modal panel, a drag) invalidates the scopes, as Chrome's
/// `HangWatcher::InvalidateActiveExpectations` does while its UI thread waits on the person.
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

    /// The running task's hang scope, read with atomics only: the watchdog reads it while the main
    /// thread is suspended, then resolves it with ``task(_:)`` once the main thread runs again.
    public struct HangScope: Sendable, Equatable {
        /// The task's packed identity (0: no task runs).
        public var packed: UInt64
        /// `CLOCK_UPTIME_RAW` nanoseconds when it started.
        public var startNanos: UInt64
        /// Its class's per-frame budget in nanoseconds (0: unbudgeted).
        public var budgetNanos: UInt64
        /// `CLOCK_UPTIME_RAW` nanoseconds when its hang deadline passes.
        public var deadlineNanos: UInt64
        /// False while a nested run loop runs, or when one started after the task did: the task
        /// waits on the person, so its time is no hang.
        public var isValid: Bool
        let postedFile: UInt
        let postedLengthLine: UInt64

        /// No task runs.
        public static let noTask = HangScope(packed: 0, startNanos: 0, budgetNanos: 0, deadlineNanos: 0, isValid: false,
                                             postedFile: 0, postedLengthLine: 0)

        /// Whether a task runs, its scope is valid and it ran past its deadline at `now`.
        public func isOverdue(at now: UInt64) -> Bool { packed != 0 && isValid && now >= deadlineNanos }
    }

    /// Packed `class << 56 | owner << 32 | sequence`; 0 while no task runs.
    private let current = Atomic<UInt64>(0)
    private let startNanos = Atomic<UInt64>(0)
    private let budgetNanos = Atomic<UInt64>(0)
    /// When the running task's hang scope ends (``hangScopeEnd(_:startNanos:idleDeadlineNanos:)``).
    private let hangAtNanos = Atomic<UInt64>(0)
    /// A sequence lock over `current`, `startNanos`, `budgetNanos` and `hangAtNanos`: odd while the main thread
    /// writes them, one higher after each write. The budget publishes an outer task again with the same packed
    /// identity after a nested one, so `current` alone cannot tell a reader that the fields beside it changed.
    private let scopeGeneration = Atomic<UInt64>(0)
    /// Action-span time charged to the task whose packed identity is in `spanCoveredFor`: kept on its hang scope
    /// when the budget publishes it again after a nested task (``endSpan(_:nowNanos:)``).
    private let spanCoveredFor = Atomic<UInt64>(0)
    private let spanCoveredNanos = Atomic<UInt64>(0)
    /// Nested run loops running now, and when the newest one started running (``nestedLoops(running:startedAt:)``).
    private let nestedLoopCount = Atomic<Int>(0)
    private let nestedLoopStartNanos = Atomic<UInt64>(0)
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

    /// Publishes a task start (main thread): its identity, budget and the end of its hang scope.
    func begin(_ workClass: MainWorkClass, owner: UInt32, sequence: UInt32, startNanos start: UInt64, budgetNanos budget: UInt64,
               hangAtNanos hangAt: UInt64, notify: Bool = true) {
        let packed = Self.pack(workClass, owner: owner, sequence: sequence)
        let covered = spanCoveredFor.load(ordering: .relaxed) == packed ? spanCoveredNanos.load(ordering: .relaxed) : 0
        publish(Published(packed: packed, startNanos: start, budgetNanos: budget, hangAtNanos: hangAt &+ covered))
        if notify, hookState.load(ordering: .acquiring) == 2 { taskStartHook.withLock { $0 }?() }
    }

    /// What the board names now (main thread, its only writer).
    var published: Published {
        Published(packed: current.load(ordering: .relaxed), startNanos: startNanos.load(ordering: .relaxed),
                  budgetNanos: budgetNanos.load(ordering: .relaxed), hangAtNanos: hangAtNanos.load(ordering: .relaxed))
    }

    /// Names `work` as the running work (main thread): a task's start, or work a span or a nested task covered.
    func publish(_ work: Published) {
        beginScopeWrite()
        startNanos.store(work.startNanos, ordering: .relaxed)
        budgetNanos.store(work.budgetNanos, ordering: .relaxed)
        hangAtNanos.store(work.hangAtNanos, ordering: .relaxed)
        current.store(work.packed, ordering: .releasing)
        endScopeWrite()
    }

    /// The running task waits in a nested run loop it ran (main thread): no task runs until the
    /// budget publishes one again (``begin(_:owner:sequence:startNanos:budgetNanos:hangAtNanos:notify:)``).
    func endParked() {
        current.store(0, ordering: .releasing)
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

    // MARK: Hang scopes

    /// The hang deadline of a task of `workClass` (Chrome's per-scope `WatchHangsInScope` timeout,
    /// base/threading/hang_watcher.h): input 100 ms, frame and userBlocking 50 ms, visible, automation,
    /// background and idle one 60 Hz frame. An idle task's frame runs from its idle deadline
    /// (``hangScopeEnd(_:startNanos:idleDeadlineNanos:)``).
    public static func hangScopeNanos(_ workClass: MainWorkClass) -> UInt64 {
        switch workClass {
        case .input: 100_000_000
        case .frame, .userBlocking: 50_000_000
        case .visible, .automation, .background, .idle: 16_666_667
        }
    }

    /// When the hang scope of a task of `workClass` that started at `startNanos` ends. An idle task
    /// with an idle deadline (`CLOCK_UPTIME_RAW` nanoseconds; 0 when it timed out) has until that
    /// deadline plus ``hangScopeNanos(_:)``.
    public static func hangScopeEnd(_ workClass: MainWorkClass, startNanos: UInt64, idleDeadlineNanos: UInt64 = 0) -> UInt64 {
        max(startNanos, idleDeadlineNanos) &+ hangScopeNanos(workClass)
    }

    /// The running task's hang scope (``HangScope/noTask`` with no task, or when the main thread is writing
    /// it). Atomics only, any thread: the watchdog reads it while the main thread is suspended.
    public var hangScope: HangScope {
        let generation = scopeGeneration.load(ordering: .acquiring)
        guard generation & 1 == 0 else { return .noTask }
        let packed = current.load(ordering: .acquiring)
        guard packed != 0 else { return .noTask }
        let start = startNanos.load(ordering: .relaxed)
        let budget = budgetNanos.load(ordering: .relaxed)
        let deadline = hangAtNanos.load(ordering: .relaxed)
        let loops = nestedLoopCount.load(ordering: .acquiring)
        let loopStart = nestedLoopStartNanos.load(ordering: .relaxed)
        let siteOwner = postedFor.load(ordering: .acquiring)
        let file = postedFile.load(ordering: .acquiring)
        let lengthLine = postedLengthLine.load(ordering: .acquiring)
        // The main thread wrote the scope between the loads (a newer task, or this one published again): none
        // is reported. The fence keeps the loads above before the generation's second load.
        atomicFence(ordering: .acquiring)
        guard scopeGeneration.load(ordering: .relaxed) == generation, current.load(ordering: .relaxed) == packed else { return .noTask }
        let site = siteOwner == packed
        return HangScope(packed: packed, startNanos: start, budgetNanos: budget, deadlineNanos: deadline,
                         isValid: loops == 0 && start > loopStart, postedFile: site ? file : 0, postedLengthLine: site ? lengthLine : 0)
    }

    /// The task a ``hangScope`` read names, with its posting site; nil for no task. Takes the owners
    /// lock: never call it while the main thread is suspended.
    public func task(_ scope: HangScope) -> Task? {
        guard scope.packed != 0 else { return nil }
        var task = Self.unpack(scope.packed, start: scope.startNanos, budget: scope.budgetNanos, name: name(of:))
        task?.postedFrom = Self.postedFrom(file: scope.postedFile, lengthLine: scope.postedLengthLine)
        return task
    }

    /// The running task's hang scope ends at `hangAt` instead (main thread: an idle task's deadline).
    func extendHangScope(to hangAt: UInt64) {
        let packed = current.load(ordering: .relaxed)
        let covered = packed != 0 && spanCoveredFor.load(ordering: .relaxed) == packed ? spanCoveredNanos.load(ordering: .relaxed) : 0
        beginScopeWrite()
        hangAtNanos.store(hangAt &+ covered, ordering: .relaxed)
        endScopeWrite()
    }

    /// Main thread, before it writes the scope's fields: readers that overlap the write see an odd generation
    /// or a changed one (the releasing fence keeps the field stores after the odd one).
    private func beginScopeWrite() {
        scopeGeneration.store(scopeGeneration.load(ordering: .relaxed) &+ 1, ordering: .relaxed)
        atomicFence(ordering: .releasing)
    }

    /// Main thread, after it wrote the scope's fields.
    private func endScopeWrite() {
        scopeGeneration.store(scopeGeneration.load(ordering: .relaxed) &+ 1, ordering: .releasing)
    }

    /// The number of nested run loops running now changed (main thread, ``MainFrameBudget``):
    /// `startedAt` is when one started running (nil when one stopped). While one runs, and for every
    /// task that started before the newest one started, no scope is valid.
    func nestedLoops(running count: Int, startedAt start: UInt64?) {
        if let start { nestedLoopStartNanos.store(start, ordering: .relaxed) }
        nestedLoopCount.store(count, ordering: .releasing)
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
        let previous = published
        let sequence = spanSequence.add(1, ordering: .relaxed).newValue | 0x8000_0000
        begin(workClass, owner: owner, sequence: sequence, startNanos: start, budgetNanos: budgetNanos,
              hangAtNanos: Self.hangScopeEnd(workClass, startNanos: start))
        return SpanToken(packed: Self.pack(workClass, owner: owner, sequence: sequence), startNanos: start, budgetNanos: budgetNanos, previous: previous)
    }

    /// Ends the span `token` began and puts back the work it covered; a span that ran past its
    /// budget is reported to the over-budget sink (the watchdog's `over_budget` record, with the
    /// stack it sampled). Atomics only unless it ran over.
    ///
    /// - Parameter nowNanos: Its end (`CLOCK_UPTIME_RAW` nanoseconds; an action's commit end).
    public func endSpan(_ token: SpanToken, nowNanos: UInt64) {
        let previous = token.previous
        let elapsed = nowNanos &- token.startNanos
        // The span's time is not the covered task's, as a nested task's is not (MainFrameBudget's childNanos).
        var hangAt = previous.hangAtNanos
        if previous.packed != 0 {
            hangAt &+= elapsed
            let covered = spanCoveredFor.load(ordering: .relaxed) == previous.packed ? spanCoveredNanos.load(ordering: .relaxed) : 0
            spanCoveredNanos.store(covered &+ elapsed, ordering: .relaxed)
            spanCoveredFor.store(previous.packed, ordering: .relaxed)
        }
        publish(previous.endingAt(hangAt))
        guard token.budgetNanos > 0, elapsed > token.budgetNanos, let sink = overBudgetSink.withLock({ $0 }),
              let task = task(packed: token.packed, startNanos: token.startNanos, budgetNanos: token.budgetNanos) else { return }
        sink(task, elapsed)
    }

    /// Installs (or removes) the receiver of finished over-budget tasks (main thread, must return at once).
    public func setOverBudgetSink(_ sink: (@Sendable (Task, _ durationNanos: UInt64) -> Void)?) {
        overBudgetSink.withLock { $0 = sink }
    }
}
