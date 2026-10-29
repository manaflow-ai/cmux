#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextCompat
public import CmuxNextWakeups
import Darwin

/// The launch's off-main job census (plans/cmux-next/chrome-parity/p08-startup.md, task 082, queue Q12): every Swift
/// task that reached the cooperative pool before startup completed, with its priority and its creator's return
/// addresses, so `startup-queue.py globaljobs` names the callers of `.utility`, `.background` and unprioritized work
/// that runs outside the BackgroundWork lanes and their launch fence.
///
/// `swift_task_enqueueGlobal_hook` (libswift_Concurrency) sees every job the runtime puts on its global executor. The
/// census keeps the first such enqueue of each task (its start on the pool: a `Task.detached`, a child task, or the
/// first `@concurrent` hop of a task made elsewhere) and only counts the rest: a task's later enqueues are its
/// resumptions, and a job that is no task is a default actor's run. A task is known by its runtime id
/// (`swift_task_getJobTaskId`, looked up with `dlsym`, never linked) in a preallocated bitmap. Chrome attributes every
/// posted task to its post site the same way (base/task/common/task_annotator.cc, `TaskAnnotator::WillQueueTask`
/// with the task's `posted_from`).
///
/// Not seen here: GCD blocks (`DispatchQueue.global().async`, which p08-startup.md section 6 counts in the source),
/// BackgroundWork lane items (they run on the lanes' own serial queues) and main-actor jobs (queue Q11).
///
/// The hook gives each job to the runtime's own enqueue (`original`) right after the record, so scheduling does not
/// change; after ``freeze()`` it costs one atomic load. A record claims a slot with one atomic add and writes the
/// slot's fields and stack (`backtrace_async`: no lock, no allocation) before it publishes the slot with a release
/// store. Debug and bench-hooks builds only, and armed only by ``environmentKey``. The hook word is taken only when it
/// is free; in an armed launch the trace's `ConcurrencyHook` finds it taken.
///
/// Memory safety: each buffer is one allocation made and initialized by init at its full size and never freed,
/// because the hook may call in for the life of the process; the census keeps its address as an integer and makes the
/// pointer at each use. A slot index comes only from the claim in ``record(taskID:priority:onMain:)``, which is checked
/// against ``capacity``; a bitmap word index is checked against the bitmap's size. A slot's fields are written once, by
/// the thread that claimed it, before the release store of its ready word; ``snapshot()`` reads them only after an
/// acquire load of that word finds it set.
///
/// ```swift
/// let census = GlobalJobCensus.armed(environment: ProcessInfo.processInfo.environment, processStartNanos: start)
/// census?.freeze(after: order.startup)
/// // later, off main:
/// let report = GlobalJobCensusReport(census.snapshot()) { addresses in frames(addresses) }
/// ```
public final class GlobalJobCensus: Sendable {
    /// The runtime's enqueue the hook hands each job to (Swift calling convention).
    typealias Original = @convention(thin) (UnownedJob) -> Void
    /// `swift_task_enqueueGlobal_hook`'s function type (swift/Runtime/Concurrency.h).
    typealias Hook = @convention(thin) (UnownedJob, Original) -> Void
    /// `swift_task_getJobTaskId`: a job's task id, 0 for a job that is no task.
    typealias JobTaskID = @convention(thin) (UnownedJob) -> UInt64

    /// `CMUX_NEXT_GLOBAL_JOB_CENSUS=1` arms the census for one launch.
    public static let environmentKey = "CMUX_NEXT_GLOBAL_JOB_CENSUS"
    /// The tasks kept (about 150 bytes each).
    public static let jobCapacity = 8_192
    /// Task ids under this are told apart (a 128 KB bitmap); a task with a higher id is counted, not kept.
    public static let taskIDLimit: UInt64 = 1 << 20
    /// The return addresses kept per task: the census's and the runtime's frames, then the creator's.
    public static let depth = 16

    /// What the hook install found.
    public enum HookState: UInt8, Sendable {
        /// Every global-executor job goes through the census.
        case installed
        /// This Swift runtime exports no `swift_task_enqueueGlobal_hook` or no `swift_task_getJobTaskId`.
        case missing
        /// Another hook (or another census) holds the word: the census sees no job.
        case busy
        /// Nothing installed it (tests drive ``record(taskID:priority:onMain:)`` themselves).
        case notInstalled

        /// The report's name.
        public var name: String {
            switch self {
            case .installed: "installed"
            case .missing: "missing"
            case .busy: "busy"
            case .notInstalled: "not_installed"
            }
        }
    }

    /// One task's first enqueue on the global executor.
    public struct Job: Sendable, Equatable {
        public var slot: Int
        public var taskID: UInt64
        /// `CLOCK_UPTIME_RAW` nanoseconds.
        public var enqueuedNanos: UInt64
        /// The job's raw `TaskPriority` (0: none stated).
        public var priority: UInt8
        /// Whether the main thread enqueued it.
        public var onMain: Bool
        /// Return addresses, the innermost first (the census's own frames included).
        public var frames: [UInt]
    }

    /// What the census counted besides the kept tasks.
    public struct Counts: Sendable, Equatable {
        /// Tasks whose first enqueue was claimed and is not published yet (a record still being written).
        public var pending = 0
        /// Tasks past ``capacity``: counted, not kept.
        public var dropped = 0
        /// Later enqueues of a kept task (its resumptions on the pool).
        public var resumptions = 0
        /// Global jobs that are no task (default actors' runs).
        public var actorJobs = 0
        /// Tasks with an id at or past ``taskIDLimit``: not told apart, so not kept.
        public var untracked = 0
    }

    /// A copy of what the census holds; the report is built from it off the main thread.
    public struct Snapshot: Sendable {
        public var hook: HookState
        public var processStartNanos: UInt64
        public var frozen: Bool
        public var jobs: [Job]
        public var counts: Counts
    }

    public let capacity: Int
    public let processStartNanos: UInt64
    private let clock: @Sendable () -> UInt64
    /// The address of the runtime's task-id reader (``JobTaskID``); 0 in a census that was not armed (tests).
    private let jobTaskIDAddress: UInt
    private let hookState = Atomic<UInt8>(HookState.notInstalled.rawValue)
    private let claims = Atomic<Int>(0)
    private let frozen = Atomic<Bool>(false)
    private let resumptions = Atomic<Int>(0)
    private let actorJobs = Atomic<Int>(0)
    private let untracked = Atomic<Int>(0)
    // The buffers' addresses (``buffer(_:_:)``). `seen`: one word per 64 task ids, bit `id % 64` of word `id / 64` set
    // at the task's first enqueue. `ready`: one word per slot, 1 once the slot's fields are written (release store).
    // The others: the slot's fields, written by the claiming thread before its ready word is set; `frames` holds
    // ``depth`` addresses per slot.
    private let seen: UInt
    private let seenWords: Int
    private let ready: UInt
    private let taskIDs: UInt
    private let enqueued: UInt
    private let priorities: UInt
    private let origins: UInt
    private let frameCounts: UInt
    private let frames: UInt

    /// The census `environment` asks for, its hook installed; nil when ``environmentKey`` is not `1`. Call first
    /// thing in `main`, before the launch starts tasks.
    public static func armed(environment: [String: String], processStartNanos: UInt64) -> GlobalJobCensus? {
        guard environment[environmentKey] == "1" else { return nil }
        let taskID = runtimeJobTaskIDAddress()
        let census = GlobalJobCensus(capacity: jobCapacity, processStartNanos: processStartNanos, jobTaskIDAddress: taskID)
        census.hookState.store(taskID == 0 ? HookState.missing.rawValue : census.install().rawValue, ordering: .releasing)
        return census
    }

    /// A census that nothing installed (tests drive ``record(taskID:priority:onMain:)``).
    ///
    /// - Parameters:
    ///   - capacity: The tasks kept.
    ///   - processStartNanos: Process start on `clock`: the zero of the report's times.
    ///   - clock: The census's clock in nanoseconds, on the same zero as `processStartNanos`.
    public convenience init(capacity: Int, processStartNanos: UInt64, clock: @escaping @Sendable () -> UInt64) {
        self.init(capacity: capacity, processStartNanos: processStartNanos, clock: clock, jobTaskIDAddress: 0)
    }

    private init(capacity: Int, processStartNanos: UInt64,
                 clock: @escaping @Sendable () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) },
                 jobTaskIDAddress: UInt) {
        let count = max(capacity, 1)
        self.capacity = count
        self.processStartNanos = processStartNanos
        self.clock = clock
        self.jobTaskIDAddress = jobTaskIDAddress
        seenWords = Int(Self.taskIDLimit / 64)
        seen = Self.buffer(seenWords, UInt64(0))
        ready = Self.buffer(count, UInt64(0))
        taskIDs = Self.buffer(count, UInt64(0))
        enqueued = Self.buffer(count, UInt64(0))
        priorities = Self.buffer(count, UInt8(0))
        origins = Self.buffer(count, false)
        frameCounts = Self.buffer(count, Int32(0))
        frames = unsafe Self.buffer(count * Self.depth, UnsafeMutableRawPointer?.none)
    }

    /// A buffer of `count` values, each `value`, that is never freed: its address.
    private static func buffer<T>(_ count: Int, _ value: T) -> UInt {
        // SAFETY: a fresh allocation, initialized here at its full size and never freed (the type's note).
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: count)
        unsafe pointer.initialize(repeating: value, count: count)
        return UInt(bitPattern: pointer)
    }

    /// The buffer at `address` (one ``buffer(_:_:)`` made) as `T`s.
    @unsafe
    private static func at<T>(_ address: UInt, _ type: T.Type) -> UnsafeMutablePointer<T> {
        // SAFETY: `address` is a buffer of `T`s that buffer(_:_:) allocated, never 0 and never freed.
        unsafe UnsafeMutablePointer<T>(bitPattern: address).unsafelyUnwrapped
    }

    /// What the hook install found.
    public var hook: HookState {
        HookState(rawValue: hookState.load(ordering: .acquiring)) ?? .notInstalled
    }

    /// Whether the census stopped recording (startup completed).
    public var isFrozen: Bool { frozen.load(ordering: .acquiring) }

    // MARK: Recording (any thread; no lock, allocation or system call but the clock read)

    /// Records one global-executor job of task `taskID` (0: a job that is no task) at `priority` (a raw
    /// `TaskPriority`), enqueued now by the calling thread, with that thread's return addresses. Keeps only a task's
    /// first job; the rest are counted.
    ///
    /// - Returns: The slot it kept the job in; nil when it only counted it, or when the census is frozen or full.
    @discardableResult
    @inline(never)
    public func record(taskID: UInt64, priority: UInt8, onMain: Bool) -> Int? {
        guard !frozen.load(ordering: .relaxed) else { return nil }
        guard taskID != 0 else {
            actorJobs.add(1, ordering: .relaxed)
            return nil
        }
        guard taskID < Self.taskIDLimit else {
            untracked.add(1, ordering: .relaxed)
            return nil
        }
        guard firstSight(of: taskID) else {
            resumptions.add(1, ordering: .relaxed)
            return nil
        }
        let slot = claims.add(1, ordering: .relaxed).oldValue
        guard slot < capacity else { return nil }
        // SAFETY: slot < capacity (checked above), and only this thread writes the slot's fields: its claim is the
        // only one that returned this index.
        unsafe Self.at(taskIDs, UInt64.self)[slot] = taskID
        unsafe Self.at(enqueued, UInt64.self)[slot] = clock()
        unsafe Self.at(priorities, UInt8.self)[slot] = priority
        unsafe Self.at(origins, Bool.self)[slot] = onMain
        var enqueuingTask: UInt32 = 0
        // SAFETY: backtrace_async writes at most `depth` addresses, into the slot's own `depth` entries of `frames`.
        let stack = unsafe Self.at(frames, UnsafeMutableRawPointer?.self) + slot * Self.depth
        let taken = unsafe backtrace_async(stack, Self.depth, &enqueuingTask)
        unsafe Self.at(frameCounts, Int32.self)[slot] = Int32(clamping: min(taken, Self.depth))
        readyWord(slot).store(1, ordering: .releasing)
        return slot
    }

    /// Stops recording; the hook then hands every job straight to the runtime. Any thread.
    public func freeze() { frozen.store(true, ordering: .releasing) }

    /// Freezes the census when `startup` completes.
    @MainActor
    public func freeze(after startup: StartupScheduler) {
        startup.whenComplete { [self] _ in freeze() }
    }

    /// Sets bit `taskID` in the bitmap; true when this call set it (the task's first job). `taskID` < ``taskIDLimit``.
    private func firstSight(of taskID: UInt64) -> Bool {
        let index = Int(taskID / 64), bit: UInt64 = 1 << (taskID % 64)
        guard index < seenWords else { return false }
        // SAFETY: index < seenWords (checked above): the word is inside the bitmap's allocation, which is never freed
        // and which allocate aligned for UInt64.
        let word = unsafe AtomicPointerSlot(Self.at(seen, UInt64.self) + index)
        var current = word.load(ordering: .relaxed)
        while current & bit == 0 {
            let swap = word.weakCompareExchange(expected: current, desired: current | bit, ordering: .relaxed)
            if swap.exchanged { return true }
            current = swap.original
        }
        return false
    }

    /// Slot `slot`'s ready word. `slot` is a claimed index under ``capacity`` (``record(taskID:priority:onMain:)``
    /// checks it, ``snapshot()`` reads under `min(claims, capacity)`).
    private func readyWord(_ slot: Int) -> AtomicPointerSlot {
        // SAFETY: 0 <= slot < capacity (both callers bound it): inside the allocation of `capacity` words, never freed.
        unsafe AtomicPointerSlot(Self.at(ready, UInt64.self) + slot)
    }

    /// The hook's work for one job: recorded unless frozen, then given to the runtime's own enqueue.
    func enqueue(_ job: UnownedJob, original: Original) {
        if !frozen.load(ordering: .relaxed), jobTaskIDAddress != 0 {
            // SAFETY: a nonzero address is the runtime's swift_task_getJobTaskId (runtimeJobTaskIDAddress), of type
            // JobTaskID; a loaded runtime image is never unloaded.
            let taskID = unsafe unsafeBitCast(jobTaskIDAddress, to: JobTaskID.self)(job)
            record(taskID: taskID & 0xFFFF_FFFF, priority: job.priority.rawValue, onMain: pthread_main_np() != 0)
        }
        original(job)
    }

    // MARK: Reading (any thread)

    /// The kept tasks in claim order, and the counts.
    public func snapshot() -> Snapshot {
        let claimed = claims.load(ordering: .acquiring)
        let kept = min(claimed, capacity)
        var jobs: [Job] = []
        jobs.reserveCapacity(kept)
        for slot in 0 ..< kept where readyWord(slot).load(ordering: .acquiring) != 0 {
            // SAFETY: slot < capacity and base + count is inside the slot's own `depth` entries of `frames`; the
            // acquire load of the slot's ready word above orders these reads after the writer's.
            let count = unsafe Int(max(0, min(Self.at(frameCounts, Int32.self)[slot], Int32(Self.depth))))
            let stack = unsafe Self.at(frames, UnsafeMutableRawPointer?.self) + slot * Self.depth
            let addresses = (0 ..< count).map { unsafe UInt(bitPattern: stack[$0]) }
            unsafe jobs.append(Job(slot: slot, taskID: Self.at(taskIDs, UInt64.self)[slot], enqueuedNanos: Self.at(enqueued, UInt64.self)[slot],
                                   priority: Self.at(priorities, UInt8.self)[slot], onMain: Self.at(origins, Bool.self)[slot],
                                   frames: addresses))
        }
        var counts = Counts()
        counts.pending = kept - jobs.count
        counts.dropped = max(0, claimed - capacity)
        counts.resumptions = resumptions.load(ordering: .relaxed)
        counts.actorJobs = actorJobs.load(ordering: .relaxed)
        counts.untracked = untracked.load(ordering: .relaxed)
        return Snapshot(hook: hook, processStartNanos: processStartNanos, frozen: isFrozen, jobs: jobs, counts: counts)
    }

    // MARK: The runtime hook

    /// The installed census's address (`Unmanaged`, retained for the process), 0 before an install. The runtime's hook
    /// is a thin function with no context: this word is how it finds the census the composition root made.
    private static let installedBits = Atomic<UInt>(0)

    /// The address of the runtime's `swift_task_getJobTaskId`, 0 when this Swift runtime exports none.
    private static func runtimeJobTaskIDAddress() -> UInt {
        // SAFETY: RTLD_DEFAULT (-2) searches every loaded image; the symbol, when found, is libswift_Concurrency's
        // exported `swift_task_getJobTaskId`, a Swift-convention function of one job pointer that returns its task id
        // (the runtime's own `UnownedJob.description` calls it). A runtime that returns a 32-bit id leaves the upper
        // half undefined: ``enqueue(_:original:)`` keeps the lower 32 bits.
        guard let symbol = unsafe dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_task_getJobTaskId") else { return 0 }
        return UInt(bitPattern: symbol)
    }

    /// The hook's function pointer as the runtime's word holds it: stored through a typed `Hook?` cell (the type the
    /// runtime declares the word with) and read back as the word.
    private static let hookBits: UInt64 = {
        let hook: Hook = { job, original in
            let bits = GlobalJobCensus.installedBits.load(ordering: .acquiring)
            // SAFETY: a nonzero word is a census install() retained and never released, so the address stays valid.
            guard bits != 0, let raw = unsafe UnsafeRawPointer(bitPattern: bits) else { return original(job) }
            unsafe Unmanaged<GlobalJobCensus>.fromOpaque(raw)._withUnsafeGuaranteedRef { $0.enqueue(job, original: original) }
        }
        // SAFETY: a fresh one-word cell, initialized, read as its 8 bytes and freed before it leaves this scope.
        let cell = UnsafeMutablePointer<Hook?>.allocate(capacity: 1)
        defer { unsafe cell.deallocate() }
        unsafe cell.initialize(to: hook)
        return unsafe UnsafeRawPointer(cell).load(as: UInt64.self)
    }()

    /// Sends every global-executor job of the process through this census. Once per process: a second census, or a
    /// hook someone else set, finds it ``HookState/busy``; the hook stays for the life of the process.
    private func install() -> HookState {
        // SAFETY: RTLD_DEFAULT (-2) searches every loaded image; the symbol, when found, is libswift_Concurrency's
        // exported `swift_task_enqueueGlobal_hook`, a pointer-sized, 8-byte aligned variable of type `Hook?`.
        guard let symbol = unsafe dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_task_enqueueGlobal_hook") else { return .missing }
        let ours = Self.hookBits
        // SAFETY: one retain the process keeps (the hook reads the address back); released at once when the word is
        // taken, before any hook saw it.
        let retained = unsafe Unmanaged.passRetained(self)
        let bits = unsafe UInt(bitPattern: retained.toOpaque())
        guard Self.installedBits.compareExchange(expected: 0, desired: bits, ordering: .acquiringAndReleasing).exchanged else {
            unsafe retained.release()
            return .busy
        }
        // SAFETY: the runtime's hook word (above), changed only by this compare-exchange: never replaced or chained.
        let word = unsafe AtomicPointerSlot(symbol.assumingMemoryBound(to: UInt64.self))
        guard word.compareExchange(expected: 0, desired: ours, ordering: .acquiringAndReleasing).exchanged else {
            // Another hook holds the word: nothing calls this census, so its retain goes.
            Self.installedBits.store(0, ordering: .releasing)
            unsafe retained.release()
            return .busy
        }
        return .installed
    }
}
#endif
