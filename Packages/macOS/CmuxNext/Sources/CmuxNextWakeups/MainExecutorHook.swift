import CoreFoundation
import CmuxNextCompat
import Darwin
import Foundation

/// The priority-ordered main executor (plans/cmux-next/chrome-parity/p06-scheduler.md, task 202, a decision-gated
/// spike; default off, feature `mainExecutorHook` or `CMUX_MAIN_EXECUTOR_HOOK=1`).
///
/// Without it every main-actor job (a `Task { @MainActor in }`, a main-inherited `Task {}`, `MainActor.run`, an
/// `await` resuming on main) is one FIFO block on the main dispatch queue, whatever its task's priority: an agent's
/// utility task's resume runs before the person's next key work if it was enqueued first. With it,
/// `swift_task_enqueueMainExecutor_hook` (libswift_Concurrency) puts each job in one of five FIFO queues chosen by its
/// priority, and a run-loop source on the main run loop runs them highest class first, oldest first within a class
/// (Chrome's `TaskQueueSelector`, base/task/sequence_manager/task_queue_selector.h). The source is in the common
/// modes, as Chrome's work source is (`MessagePumpCFRunLoopBase::work_source_`,
/// base/message_loop/message_pump_apple.mm), so menu tracking and modal panels run main-actor jobs too.
///
/// The classes (``workClass(priority:inInputTurn:)``): a job the main thread enqueues while a discrete input's
/// dispatch is open is ``MainWorkClass/input``; otherwise `.high` and above is `userBlocking`, `.medium` and no
/// priority are `visible`, `.low` (utility) is `automation`, `.background` is `background`. A task makes one job at
/// a time (its next one only after the last one ran), and each class is FIFO, so one task's jobs keep their order.
///
/// Each pass runs at most the jobs queued when it began (jobs they enqueue wait for the next pass, after the run
/// loop's observers and the commit), at least one, and stops before a job below ``MainWorkClass/input`` while a
/// person's input is pending (``SessionInputPending`` through the scheduler's budget), checked at most every
/// ``inputCheckNanos``. The source signals itself again for what is left.
///
/// The hook word is taken only when it is free (the p04-input MainJobGate and the p08 main-job census want the same
/// word: the first one wins and the others find it ``State/busy``), and stays for the life of the process. Only
/// the composition root installs it (``MainWorkScheduler/installMainExecutorHook(requested:)``), and, for the gate's
/// test runs, the first scheduler of a process launched with `CMUX_MAIN_EXECUTOR_HOOK=1`.
///
/// ```swift
/// // The composition root, once:
/// mainWork.installMainExecutorHook(requested: MainExecutorHook.isRequested(feature: features.isEnabled(.mainExecutorHook),
///                                                                          environment: ProcessInfo.processInfo.environment))
/// // A test drives a hook it never installs:
/// let hook = MainExecutorHook(yieldsToInput: { false })
/// hook.enqueue(priority: TaskPriority.low.rawValue) { ran.append("low") }
/// hook.runPass()
/// ```
public final class MainExecutorHook: Sendable {
    /// The runtime's own main-executor enqueue the hook replaces (Swift calling convention).
    typealias Original = @convention(thin) (UnownedJob) -> Void
    /// `swift_task_enqueueMainExecutor_hook`'s function type (swift/Runtime/Concurrency.h).
    typealias Hook = @convention(thin) (UnownedJob, Original) -> Void

    /// `CMUX_MAIN_EXECUTOR_HOOK=1` turns the hook on for one launch (or one test process); `0` keeps it off even
    /// when the feature is on.
    public static let environmentKey = "CMUX_MAIN_EXECUTOR_HOOK"
    /// The longest a pass trusts its last pending-input answer (the budget's own cache, MainFrameBudget.inputPending).
    public static let inputCheckNanos: UInt64 = 250_000
    /// The classes a main-actor job runs in, highest first: the order a pass picks them in.
    public static let classes: [MainWorkClass] = [.input, .userBlocking, .visible, .automation, .background]

    /// What the install found.
    public enum State: UInt8, Sendable {
        /// Every main-actor job of the process goes through the hook's queues.
        case installed
        /// This Swift runtime exports no `swift_task_enqueueMainExecutor_hook`.
        case missing
        /// Another hook (or another scheduler's) holds the word: main-actor jobs stay on the main dispatch queue.
        case busy
        /// Not asked for (the feature and the environment are off): nothing was installed.
        case off

        /// The report's name.
        public var name: String {
            switch self {
            case .installed: "installed"
            case .missing: "missing"
            case .busy: "busy"
            case .off: "off"
            }
        }
    }

    /// The hook's counters (`debug.main_budget`, tests).
    public struct Stats: Sendable, Equatable {
        /// Jobs run, by class, in ``MainExecutorHook/classes`` order.
        public var ranByClass: [Int] = Array(repeating: 0, count: MainExecutorHook.classes.count)
        /// Jobs queued and not run yet.
        public var queued = 0
        /// Passes the run-loop source ran.
        public var passes = 0
        /// Passes that stopped for a person's pending input with work left.
        public var yields = 0

        /// Jobs of `workClass` run so far.
        public func ran(_ workClass: MainWorkClass) -> Int {
            MainExecutorHook.classes.firstIndex(of: workClass).map { ranByClass[$0] } ?? 0
        }
    }

    /// One queued piece of main-actor work.
    enum Item: Sendable {
        /// A runtime job the hook took.
        case job(UnownedJob)
        /// A main-actor closure (``enqueue(priority:_:)``: tests and the gate's probes).
        case work(@MainActor @Sendable () -> Void)
    }

    /// One class's FIFO.
    struct Bucket {
        private var items: [Item] = []
        private var head = 0

        var isEmpty: Bool { head == items.count }

        mutating func push(_ item: Item) { items.append(item) }

        mutating func pop() -> Item? {
            guard head < items.count else { return nil }
            let item = items[head]
            head += 1
            if head == items.count {
                items.removeAll(keepingCapacity: true)
                head = 0
            } else if head >= 64, head * 2 >= items.count {
                items.removeFirst(head)
                head = 0
            }
            return item
        }
    }

    /// The queues and the source, behind one lock: the hook enqueues from any thread.
    struct Queues {
        var buckets = Array(repeating: Bucket(), count: MainExecutorHook.classes.count)
        var stats = Stats()
        /// The run-loop source is signaled and has not started its pass yet.
        var signaled = false
        /// The main run loop's source (nil until ``MainExecutorHook/install()``, and in tests).
        var source: CFRunLoopSource?

        mutating func push(_ item: Item, at index: Int) {
            buckets[index].push(item)
            stats.queued += 1
        }

        /// The oldest item of the highest non-empty class; with `inputOnly`, only an ``MainWorkClass/input`` one.
        mutating func pop(inputOnly: Bool) -> Item? {
            let end = inputOnly ? 1 : buckets.count
            for index in 0 ..< end {
                guard let item = buckets[index].pop() else { continue }
                stats.queued -= 1
                stats.ranByClass[index] += 1
                return item
            }
            return nil
        }

        /// Signals the source once until its next pass begins (nothing in tests, which have no source).
        mutating func signal() {
            guard !signaled, let source else { return }
            signaled = true
            CFRunLoopSourceSignal(source)
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    private let queues = Mutex(Queues())
    /// Open discrete-input dispatches (``noteInputTurn(began:)``), read by the hook on the main thread.
    private let inputTurns = Atomic<Int>(0)
    private let yieldsToInput: @MainActor @Sendable () -> Bool
    private let clock: @Sendable () -> UInt64

    /// - Parameters:
    ///   - yieldsToInput: Whether a person's input is pending now (the scheduler: its budget's pending-input source
    ///     and the board's injected input count).
    ///   - clock: `CLOCK_UPTIME_RAW` nanoseconds (tests: a fake), for the input check's cache.
    public init(yieldsToInput: @escaping @MainActor @Sendable () -> Bool,
                clock: @escaping @Sendable () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }) {
        self.yieldsToInput = yieldsToInput
        self.clock = clock
    }

    /// Whether the launch asks for the hook: `CMUX_MAIN_EXECUTOR_HOOK=1`, or the feature unless the environment says
    /// `0`.
    public static func isRequested(feature: Bool, environment: [String: String]) -> Bool {
        switch environment[environmentKey] {
        case "1": true
        case "0": false
        default: feature
        }
    }

    /// The process's environment asked for the hook (read once): the first scheduler installs it, so a whole test
    /// run goes through it (the gate's `CMUX_MAIN_EXECUTOR_HOOK=1 swift test`).
    static let launchEnvironmentAsks = ProcessInfo.processInfo.environment[environmentKey] == "1"

    /// The class a job of raw `priority` (`TaskPriority.rawValue`, 0 for none) runs in. `inInputTurn`: the main
    /// thread enqueued it during a discrete input's dispatch.
    public static func workClass(priority: UInt8, inInputTurn: Bool) -> MainWorkClass {
        classes[classIndex(priority: priority, inInputTurn: inInputTurn)]
    }

    /// ``workClass(priority:inInputTurn:)``'s index in ``classes``.
    static func classIndex(priority: UInt8, inInputTurn: Bool) -> Int {
        if inInputTurn { return 0 }
        if priority == 0 { return 2 }
        if priority >= TaskPriority.high.rawValue { return 1 }
        if priority >= TaskPriority.medium.rawValue { return 2 }
        if priority >= TaskPriority.low.rawValue { return 3 }
        return 4
    }

    /// A discrete input's dispatch began or ended on the main thread (``MainWorkScheduler/noteDiscreteDispatch(began:)``):
    /// main-actor jobs the main thread enqueues meanwhile run as ``MainWorkClass/input``.
    @MainActor
    public func noteInputTurn(began: Bool) {
        if began {
            inputTurns.add(1, ordering: .relaxed)
        } else if inputTurns.load(ordering: .relaxed) > 0 {
            inputTurns.subtract(1, ordering: .relaxed)
        }
    }

    /// Queues `body` as a main-actor job of raw `priority` would be queued (tests and the gate's probes). Any thread.
    public func enqueue(priority: UInt8, _ body: @escaping @MainActor @Sendable () -> Void) {
        enqueue(.work(body), priority: priority)
    }

    /// The counters now. Any thread.
    public var stats: Stats { queues.withLock { $0.stats } }

    func enqueue(_ item: Item, priority: UInt8) { // perf-hot: 1us main-job-gate (every main-actor job while installed)
        let inInputTurn = pthread_main_np() != 0 && inputTurns.load(ordering: .relaxed) > 0
        let index = Self.classIndex(priority: priority, inInputTurn: inInputTurn)
        queues.withLock { queues in
            queues.push(item, at: index)
            queues.signal()
        }
    }

    /// One pass of the run-loop source: the jobs queued when it began, highest class first, until a person's input
    /// is pending (after the first job; ``MainWorkClass/input`` jobs still run). What is left signals the next pass.
    @MainActor
    public func runPass() {
        let limit = queues.withLock { queues in
            queues.signaled = false
            queues.stats.passes += 1
            return queues.stats.queued
        }
        var ran = 0
        var checkedAt: UInt64?
        var inputPending = false
        var yielded = false
        while ran < limit {
            if ran > 0 {
                let now = clock()
                if checkedAt.map({ now &- $0 >= Self.inputCheckNanos }) ?? true {
                    inputPending = yieldsToInput()
                    checkedAt = now
                }
            }
            let inputOnly = inputPending
            guard let item = queues.withLock({ $0.pop(inputOnly: inputOnly) }) else {
                yielded = inputOnly
                break
            }
            run(item)
            ran += 1
        }
        queues.withLock { queues in
            if yielded { queues.stats.yields += 1 }
            if queues.stats.queued > 0 { queues.signal() }
        }
    }

    @MainActor
    private func run(_ item: Item) {
        switch item {
        case let .job(job): job.runSynchronously(on: MainActor.sharedUnownedExecutor)
        case let .work(body): body()
        }
    }

    // MARK: The runtime hook

    /// The installed hook's address (`Unmanaged`, retained for the process), 0 before an install. The runtime's hook
    /// is a thin function with no context: this word is how it finds the hook the scheduler made.
    private static let installedBits = Atomic<UInt>(0)

    /// The installed hook, nil while none is (`debug.main_budget`, the gate's tests).
    public static var installed: MainExecutorHook? {
        let bits = installedBits.load(ordering: .acquiring)
        // SAFETY: a nonzero word is a hook install() retained and never released, so the address stays valid.
        guard bits != 0, let raw = unsafe UnsafeRawPointer(bitPattern: bits) else { return nil }
        return unsafe Unmanaged<MainExecutorHook>.fromOpaque(raw).takeUnretainedValue()
    }

    /// The hook's function pointer as the runtime's word holds it: stored through a typed `Hook?` cell (the type the
    /// runtime declares the word with) and read back as the word.
    private static let hookBits: UInt64 = {
        let hook: Hook = { job, original in
            let bits = MainExecutorHook.installedBits.load(ordering: .acquiring)
            // SAFETY: a nonzero word is a hook install() retained and never released, so the address stays valid.
            guard bits != 0, let raw = unsafe UnsafeRawPointer(bitPattern: bits) else { return original(job) }
            unsafe Unmanaged<MainExecutorHook>.fromOpaque(raw)._withUnsafeGuaranteedRef { $0.enqueue(.job(job), priority: job.priority.rawValue) }
        }
        // SAFETY: a fresh one-word cell, initialized, read as its 8 bytes and freed before it leaves this scope.
        let cell = UnsafeMutablePointer<Hook?>.allocate(capacity: 1)
        defer { unsafe cell.deallocate() }
        unsafe cell.initialize(to: hook)
        return unsafe UnsafeRawPointer(cell).load(as: UInt64.self)
    }()

    /// Sends every main-actor job of the process through this hook's queues, run by a source on the main run loop.
    /// Once per process: a second hook, or a hook someone else set, finds it ``State/busy``; the hook stays for the
    /// life of the process.
    @MainActor
    public func install() -> State {
        // SAFETY: RTLD_DEFAULT (-2) searches every loaded image; the symbol, when found, is libswift_Concurrency's
        // exported `swift_task_enqueueMainExecutor_hook`, a pointer-sized, 8-byte aligned variable of type `Hook?`.
        guard let symbol = unsafe dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_task_enqueueMainExecutor_hook") else {
            return .missing
        }
        // SAFETY: one retain the process keeps (the hook and the source read the address back); released at once
        // when the word is taken, before any job reached the hook.
        let retained = unsafe Unmanaged.passRetained(self)
        let bits = unsafe UInt(bitPattern: retained.toOpaque())
        guard Self.installedBits.compareExchange(expected: 0, desired: bits, ordering: .acquiringAndReleasing).exchanged else {
            unsafe retained.release()
            return .busy
        }
        attachSource()
        // SAFETY: the runtime's hook word (above), changed only by this compare-exchange: never replaced or chained.
        let word = unsafe AtomicPointerSlot(symbol.assumingMemoryBound(to: UInt64.self))
        guard word.compareExchange(expected: 0, desired: Self.hookBits, ordering: .acquiringAndReleasing).exchanged else {
            // Another hook holds the word: no job comes here, so the source and the retain go.
            detachSource()
            Self.installedBits.store(0, ordering: .releasing)
            unsafe retained.release()
            return .busy
        }
        return .installed
    }

    /// Adds the pass's source to the main run loop in the common modes.
    @MainActor
    private func attachSource() {
        // install() keeps this hook retained while the source is on the run loop (detachSource() invalidates it
        // before that retain is released).
        queues.withLock { $0.source = WorkSource.attach(self) }
    }

    @MainActor
    private func detachSource() {
        queues.withLock { queues in
            if let source = queues.source { CFRunLoopSourceInvalidate(source) }
            queues.source = nil
            queues.signaled = false
        }
    }
}
