import CmuxNextCompat
import Darwin

/// The Swift runtime's global-enqueue hook (`swift_task_enqueueGlobal_hook`, libswift_Concurrency): every job
/// the runtime puts on its global concurrent executor (the cooperative pool: detached and child tasks,
/// default-actor jobs) passes through it, so a recording sees cooperative-pool work the way Chrome's
/// `TaskAnnotator::WillQueueTask` sees every posted task (base/task/common/task_annotator.cc).
///
/// Phase 1 (task p09-observability-123) only measures. The hook writes one `task.post` record per job
/// while the trace's task category is on, then hands the job to the runtime's own enqueue, which it
/// receives as `original`: scheduling does not change. The `task.post` records are the job count
/// (per priority, from arg0). Off, the hook costs the category-flag load and a tail call into
/// `original`. Whether a cmux-owned executor runs these jobs (phase 2) is open; see
/// plans/cmux-next/threading-model.md, "Swift global-enqueue hook".
///
/// The hook has no context argument, so it writes to ``TraceRuntime/shared`` (the reviewed C-hook case of
/// that exception). The runtime promises nothing about this symbol: when `dlsym` does not find it,
/// ``init()`` throws and the app runs without the records.
///
/// ```swift
/// try ConcurrencyHook().install()
/// ```
public struct ConcurrencyHook: Sendable {
    /// `swift_task_enqueueGlobal_original`: the runtime's own enqueue (Swift calling convention).
    typealias Original = @convention(thin) (UnownedJob) -> Void
    /// `swift_task_enqueueGlobal_hook`'s function type.
    typealias Hook = @convention(thin) (UnownedJob, Original) -> Void

    /// `SignpostCategory.task.traceBit` (plans/cmux-next/trace.md "Category bits"; CmuxNextSignposts sits
    /// above this module, so the bit is repeated here and pinned by ConcurrencyHookCatalogTests).
    static let taskCategoryBit: UInt8 = 12
    /// `SignpostName.taskPost.rawValue`, pinned the same way.
    static let taskPostName: UInt16 = 50
    /// Set in every job flow id: a job address never collides with a key flow id (pid in the high 32 bits).
    static let jobFlowBit: UInt64 = 1 << 63
    /// Where arg0 holds the job's Swift priority (`JobPriority.rawValue`); bits 0-15 hold the post site's
    /// interned name, 0 here: the runtime does not say where a global enqueue was posted.
    static let priorityShift: UInt64 = 16

    /// The hook word: the runtime's `swift_task_enqueueGlobal_hook`, or a test's own word.
    let slot: AtomicPointerSlot

    /// The hook of this process's Swift runtime.
    ///
    /// - Throws: ``InstallError/runtimeHookMissing`` when the runtime does not export the hook.
    public init() throws(InstallError) {
        // RTLD_DEFAULT: the symbol lives in libswift_Concurrency, loaded with the app.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_task_enqueueGlobal_hook") else {
            throw .runtimeHookMissing
        }
        self.init(slot: AtomicPointerSlot(symbol.assumingMemoryBound(to: UInt64.self)))
    }

    /// A hook over `slot` (tests pass a word of their own).
    init(slot: AtomicPointerSlot) {
        self.slot = slot
    }

    /// Installs the hook when the word is empty. It stays installed for the life of the process: it is
    /// static code, and an uninstall could race a pool thread that already read the word.
    ///
    /// - Returns: Whether this call installed it (false: it already was).
    /// - Throws: ``InstallError/hookTaken`` when another hook holds the word; it is never replaced or chained.
    @discardableResult
    public func install() throws(InstallError) -> Bool {
        _ = TraceRuntime.shared.categoryMask // initialized here, never first inside an enqueue
        let ours = Self.hookBits
        let result = slot.compareExchange(expected: 0, desired: ours, ordering: .acquiringAndReleasing)
        if result.exchanged { return true }
        if result.original == ours { return false }
        throw .hookTaken
    }

    /// Whether the word holds this hook.
    public var isInstalled: Bool {
        slot.load(ordering: .acquiring) == Self.hookBits
    }

    /// The hook's function pointer as the word holds it: stored through a typed `Hook?` cell (the type
    /// the runtime declares the word with) and read back as the word.
    static let hookBits: UInt64 = {
        let hook: Hook = { job, original in ConcurrencyHook.enqueue(job, original) }
        let cell = UnsafeMutablePointer<Hook?>.allocate(capacity: 1)
        defer { cell.deallocate() }
        cell.initialize(to: hook)
        return UnsafeRawPointer(cell).load(as: UInt64.self)
    }()

    /// The hook body. Off: one category-flag load, a branch, and the runtime's enqueue as a tail call.
    @inline(__always)
    static func enqueue(_ job: UnownedJob, _ original: Original) { // perf-hot: 5ns swift-global-enqueue (every cooperative-pool job)
        let runtime = TraceRuntime.shared
        if runtime.isEnabled(categoryBit: taskCategoryBit) {
            post(priority: job.priority.rawValue, job: unsafeBitCast(job, to: UInt.self), on: runtime)
        }
        original(job)
    }

    /// Writes one `task.post` record for a job: a flow-out, arg0 the priority (bits 16-23) and no
    /// post site, arg1 the job's address with ``jobFlowBit`` as its flow id (a task keeps its address
    /// across its resumptions, so its posts share the flow id). Out of line, so the off path stays small.
    @inline(never)
    static func post(priority: UInt8, job: UInt, on runtime: TraceRuntime) {
        runtime.write(name: taskPostName, categoryBit: taskCategoryBit, phase: .flowOut,
                      arg0: UInt64(priority) << priorityShift, arg1: UInt64(job) | jobFlowBit)
    }
}

extension ConcurrencyHook {
    /// Why the hook is not installed.
    public enum InstallError: Error, Sendable, Equatable {
        /// The Swift runtime does not export `swift_task_enqueueGlobal_hook`.
        case runtimeHookMissing
        /// Another hook holds the word (a test library, a tool); cmux leaves it in place.
        case hookTaken
    }
}
