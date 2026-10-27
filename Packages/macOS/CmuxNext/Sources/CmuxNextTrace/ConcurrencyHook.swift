import CmuxNextCompat
import Darwin
import os

/// The Swift runtime's global-enqueue hook (`swift_task_enqueueGlobal_hook`, libswift_Concurrency): every job
/// the runtime puts on its global concurrent executor (the cooperative pool: detached and child tasks,
/// default-actor jobs, task resumptions) passes through it, so a recording sees cooperative-pool work the way
/// Chrome's `TaskAnnotator::WillQueueTask` sees every posted task (base/task/common/task_annotator.cc).
///
/// Phase 1 (task p09-observability-123) only measures. Once installed, the hook word holds one of two static
/// hooks, and the trace runtime's category writer picks which one, as Chrome's `TraceLog` tells its
/// `EnabledStateObserver`s when tracing starts and stops (base/trace_event/trace_log.h). While the `task`
/// category records, the recording hook writes one `task.post` instant per job, then calls the runtime's own
/// enqueue, which it receives as `original`. Otherwise the pass-through hook only tail-calls `original`: off,
/// cmux adds no load to the runtime's own load of its hook word. Scheduling never changes. The `task.post`
/// records are the job count (per priority, from arg0). Whether a cmux-owned executor runs these jobs (phase 2)
/// is open; see plans/cmux-next/threading-model.md, "Swift global-enqueue hook".
///
/// Once installed, the word is never 0 again: the runtime reads it with a plain load and may load it twice
/// between its null check and its call. Both hooks are static code, so a pool thread that loaded the other one
/// still runs correct code.
///
/// The hook has no context argument, so the recording hook writes to ``TraceRuntime/shared`` (the reviewed
/// C-hook case of that exception), and only that runtime's `task` bit picks the hook. The runtime promises
/// nothing about this symbol: when `dlsym` does not find it, ``init()`` throws and the app runs without the
/// records. The debug launch census (CmuxNextLaunch `GlobalJobCensus`) takes the same word when it is armed;
/// then ``install()`` throws ``InstallError/hookTaken``.
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
    /// Where arg0 holds the job's Swift priority (`JobPriority.rawValue`). Bits 0-47 are a post site's file
    /// id and line in `task.post` (trace.md); they stay 0 here: the runtime does not say where a job was posted.
    static let priorityShift: UInt64 = 48

    /// The hook word: the runtime's `swift_task_enqueueGlobal_hook`, or a test's own word.
    let slot: AtomicPointerSlot
    /// The hook word's address, which the runtime that picks the hook keeps (``TraceRuntime/concurrencyHookWord``).
    let wordAddress: UInt64

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
        unsafe self.init(word: symbol.assumingMemoryBound(to: UInt64.self))
    }

    /// A hook over the 8-byte aligned word at `word`, which stays valid for the process (tests pass a word of
    /// their own that outlives every runtime that picks its hook).
    init(word: UnsafeMutablePointer<UInt64>) {
        slot = unsafe AtomicPointerSlot(word)
        wordAddress = unsafe UInt64(UInt(bitPattern: word))
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

    /// Installs the hook when the word is empty; ``TraceRuntime/shared``'s `task` bit picks the hook from then
    /// on. It stays installed for the life of the process.
    ///
    /// - Returns: Whether this call installed it (false: it already was).
    /// - Throws: ``InstallError/hookTaken`` when another hook holds the word; it is never replaced or chained.
    @discardableResult
    public func install() throws(InstallError) -> Bool {
        try install(following: .shared) // also initializes `shared` here, never first inside an enqueue
    }

    /// Installs the hook when the word is empty, and makes `runtime`'s category writer pick the hook from its
    /// `task` bit from now on. The app passes ``TraceRuntime/shared``, the runtime the recording hook writes to;
    /// a test passes its own runtime over its own word.
    func install(following runtime: TraceRuntime) throws(InstallError) -> Bool {
        let first = runtime.isEnabled(categoryBit: Self.taskCategoryBit) ? Self.recordingBits : Self.passThroughBits
        let result = slot.compareExchange(expected: 0, desired: first, ordering: .sequentiallyConsistent)
        guard result.exchanged else {
            guard Self.isOurs(result.original) else { throw .hookTaken }
            return false
        }
        runtime.concurrencyHookWord.store(wordAddress, ordering: .sequentiallyConsistent)
        // A category change that found no word yet stored its flags before the store above: read them again.
        runtime.mirrorConcurrencyHook()
        return true
    }

    /// Whether the word holds one of this type's hooks.
    public var isInstalled: Bool {
        Self.isOurs(slot.load(ordering: .acquiring))
    }

    /// Whether the word holds the recording hook.
    var isRecording: Bool {
        slot.load(ordering: .acquiring) == Self.recordingBits
    }

    /// Swaps the word to the recording hook (`recording` true) or to the pass-through hook. A word that holds
    /// neither (empty, or another library's hook) stays as it is.
    func select(recording: Bool) {
        let (from, to) = recording ? (Self.passThroughBits, Self.recordingBits) : (Self.recordingBits, Self.passThroughBits)
        slot.compareExchange(expected: from, desired: to, ordering: .sequentiallyConsistent)
    }

    /// Whether `bits` is one of this type's hooks.
    static func isOurs(_ bits: UInt64) -> Bool {
        bits == passThroughBits || bits == recordingBits
    }

    /// The pass-through hook as the word holds it: the runtime's enqueue as a tail call, nothing else.
    static let passThroughBits: UInt64 = {
        let hook: Hook = { job, original in original(job) }
        return ConcurrencyHook.bits(of: hook)
    }()

    /// The recording hook as the word holds it.
    static let recordingBits: UInt64 = {
        let hook: Hook = { job, original in ConcurrencyHook.record(job, original) }
        return ConcurrencyHook.bits(of: hook)
    }()

    /// `hook`'s function pointer as the word holds it: stored through a typed `Hook?` cell (the type the
    /// runtime declares the word with) and read back as the word.
    private static func bits(of hook: Hook) -> UInt64 {
        // SAFETY: a fresh one-word cell, initialized, read as its 8 bytes and freed before it leaves this scope.
        let cell = UnsafeMutablePointer<Hook?>.allocate(capacity: 1)
        defer { unsafe cell.deallocate() }
        unsafe cell.initialize(to: hook)
        return unsafe UnsafeRawPointer(cell).load(as: UInt64.self)
    }

    /// The recording hook's body. Its flag check covers a pool thread that loaded this hook just before the
    /// `task` bit turned off.
    @inline(__always)
    static func record(_ job: UnownedJob, _ original: Original) { // perf-hot: 60ns swift-global-enqueue (every cooperative-pool job while task records: one ring write)
        let runtime = TraceRuntime.shared
        if runtime.isEnabled(categoryBit: taskCategoryBit) {
            post(priority: job.priority.rawValue, job: unsafe unsafeBitCast(job, to: UInt.self), on: runtime)
        }
        original(job)
    }

    /// Writes one `task.post` record for a job: an instant, arg0 the priority (bits 48-55) and no post site,
    /// arg1 the job's address. The address is no flow id: a later task gets a freed task's memory, and a
    /// default actor is the same job in every run. Out of line, so the hook stays small.
    @inline(never)
    static func post(priority: UInt8, job: UInt, on runtime: TraceRuntime) {
        runtime.write(name: taskPostName, categoryBit: taskCategoryBit, phase: .instant,
                      arg0: UInt64(priority) << priorityShift, arg1: UInt64(job))
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

extension TraceRuntime {
    /// Points the hook word that follows this runtime (``ConcurrencyHook/install()``) at the recording hook
    /// while the `task` category records, and at the pass-through hook otherwise. Every category change calls it
    /// after it stores the flags. It reads the flags again after its swap, so a change that raced the swap never
    /// leaves the wrong hook.
    func mirrorConcurrencyHook() {
        let address = concurrencyHookWord.load(ordering: .sequentiallyConsistent)
        // SAFETY: a nonzero address is the hook word ConcurrencyHook.install(following:) stored: the runtime's hook
        // variable, or a test's word that outlives its runtime; both 8-byte aligned.
        guard address != 0, let word = unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(address)) else { return }
        let hook = unsafe ConcurrencyHook(word: word)
        let bit = UInt64(1) << UInt64(ConcurrencyHook.taskCategoryBit)
        var recording = categoryFlags.load(ordering: .sequentiallyConsistent) & bit != 0
        // wakeup-allow: bounded: never waits; it swaps again only when another writer changed the task bit during its swap.
        while true {
            hook.select(recording: recording)
            let now = categoryFlags.load(ordering: .sequentiallyConsistent) & bit != 0
            if now == recording { return }
            recording = now
        }
    }
}
