import CmuxNextCompat
import Darwin
import os

/// The Swift runtime's global-enqueue hook (`swift_task_enqueueGlobal_hook`, libswift_Concurrency): every job
/// the runtime puts on its global concurrent executor (the cooperative pool: detached and child tasks,
/// default-actor jobs, task resumptions) passes through it, so a recording sees cooperative-pool work the way
/// Chrome's `TaskAnnotator::WillQueueTask` sees every posted task (base/task/common/task_annotator.cc).
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
/// ``init()`` throws and the app runs without the records. The debug launch census (CmuxNextLaunch
/// `GlobalJobCensus`) takes the same word when it is armed; then ``install()`` throws
/// ``InstallError/hookTaken``.
///
/// ```swift
/// ConcurrencyHook.installInProcess() // TraceBlackBoxFileSteps.startApp, once the black box is attached
/// ```
public struct ConcurrencyHook: Sendable {
    /// `swift_task_enqueueGlobal_original`: the runtime's own enqueue (Swift calling convention).
    typealias Original = @convention(thin) (UnownedJob) -> Void
    /// `swift_task_enqueueGlobal_hook`'s function type (swift/Runtime/Concurrency.h).
    typealias Hook = @convention(thin) (UnownedJob, Original) -> Void

    /// `SignpostCategory.task.traceBit` (plans/cmux-next/trace.md "Category bits"; CmuxNextSignposts sits
    /// above this module, so the bit is repeated here and pinned by ConcurrencyHookCatalogTests).
    static let taskCategoryBit: UInt8 = 12
    /// `SignpostName.taskPost.rawValue`, pinned the same way.
    static let taskPostName: UInt16 = 50
    /// Set in every job flow id. Bit 63 alone is a posted item's tag (`TaskTrace.flowTag`, over a counter
    /// from 1); bit 62 as well keeps a job's id apart from those, and a job address never reaches bit 62.
    static let jobFlowTag: UInt64 = 0b11 << 62
    /// Where arg0 holds the job's Swift priority (`JobPriority.rawValue`). Bits 0-47 are a post site's file
    /// id and line in `task.post` (trace.md); they stay 0 here: the runtime does not say where a job was posted.
    static let priorityShift: UInt64 = 48

    /// The hook word: the runtime's `swift_task_enqueueGlobal_hook`, or a test's own word.
    let slot: AtomicPointerSlot

    /// The hook of this process's Swift runtime.
    ///
    /// - Throws: ``InstallError/runtimeHookMissing`` when the runtime does not export the hook.
    public init() throws(InstallError) {
        // SAFETY: RTLD_DEFAULT (-2) searches every loaded image; the symbol, when found, is libswift_Concurrency's
        // exported `swift_task_enqueueGlobal_hook`, a pointer-sized, 8-byte aligned variable of type `Hook?` that
        // lives as long as the process (a loaded runtime image is never unloaded).
        guard let symbol = unsafe dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_task_enqueueGlobal_hook") else {
            throw .runtimeHookMissing
        }
        self.init(slot: unsafe AtomicPointerSlot(symbol.assumingMemoryBound(to: UInt64.self)))
    }

    /// A hook over `slot` (tests pass a word of their own).
    init(slot: AtomicPointerSlot) {
        self.slot = slot
    }

    /// Installs the hook into this process's runtime. When it cannot (no hook symbol, or another hook holds the
    /// word), it logs why once and the process runs without the records.
    ///
    /// - Returns: Why the hook is not installed; nil when it is (by this call or an earlier one).
    @discardableResult
    public static func installInProcess() -> InstallError? {
        do throws(InstallError) {
            try ConcurrencyHook().install()
            return nil
        } catch {
            Logger(subsystem: "com.cmuxterm.app.next", category: "trace")
                .notice("Swift global-enqueue hook not installed: \(String(describing: error), privacy: .public)")
            return error
        }
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
        // SAFETY: a fresh one-word cell, initialized, read as its 8 bytes and freed before it leaves this scope.
        let cell = UnsafeMutablePointer<Hook?>.allocate(capacity: 1)
        defer { unsafe cell.deallocate() }
        unsafe cell.initialize(to: hook)
        return unsafe UnsafeRawPointer(cell).load(as: UInt64.self)
    }()

    /// The hook body. Off: one category-flag load, a branch, and the runtime's enqueue as a tail call.
    @inline(__always)
    static func enqueue(_ job: UnownedJob, _ original: Original) { // perf-hot: 5ns swift-global-enqueue (every cooperative-pool job)
        let runtime = TraceRuntime.shared
        if runtime.isEnabled(categoryBit: taskCategoryBit) {
            post(priority: job.priority.rawValue, job: unsafe unsafeBitCast(job, to: UInt.self), on: runtime)
        }
        original(job)
    }

    /// Writes one `task.post` record for a job: a flow-out, arg0 the priority (bits 48-55) and no post
    /// site, arg1 the job's address with ``jobFlowTag`` as its flow id (a task keeps its address across its
    /// resumptions, so its posts share the flow id). Out of line, so the off path stays small.
    @inline(never)
    static func post(priority: UInt8, job: UInt, on runtime: TraceRuntime) {
        runtime.write(name: taskPostName, categoryBit: taskCategoryBit, phase: .flowOut,
                      arg0: UInt64(priority) << priorityShift, arg1: UInt64(job) | jobFlowTag)
    }
}

extension ConcurrencyHook {
    /// Why the hook is not installed.
    public enum InstallError: Error, Sendable, Equatable {
        /// The Swift runtime does not export `swift_task_enqueueGlobal_hook`.
        case runtimeHookMissing
        /// Another hook holds the word (the armed launch census, a test library, a tool); cmux leaves it in place.
        case hookTaken
    }
}
