#if DEBUG || CMUX_BLOCKING_CHECKS
internal import Darwin
internal import Dispatch
#endif

/// Where a checked blocking call runs, as the blocking detector classifies the calling thread: Chrome's
/// per-thread `ThreadRestrictions`, which disallow blocking on the UI thread and on every pool thread that
/// runs a task without `MayBlock()` (base/task/thread_pool/task_tracker.cc, `RunTask`).
///
/// The detector reads, in order: the main thread; else the thread's own mark (``runAsLane(_:)`` or
/// ``runAsCPULane(_:)`` around a `BackgroundWork` lane item, ``allowBlocking(_:_:)`` off the main thread, or a
/// named thread's first check);
/// else the label of the dispatch queue running the call. A GCD root queue (label prefix `com.apple.root.`) is
/// ``pool``; the Swift cooperative pool's queues are root queues (`com.apple.root.user-initiated-qos.cooperative`,
/// libdispatch queue.c `_dispatch_root_queues`), so the one prefix compare covers them. Any other queue, a named
/// serial queue included, is ``dedicated``. A thread that runs no queue reads the default root queue's label, so
/// it is ``pool`` unless it has a pthread name (every cmux `Thread` is named: threading-model.md, "Registered
/// threads and queues"; pool workers are not). The first check on such a thread reads its name and keeps the
/// answer in the thread's flags: a named thread is marked dedicated, so its later checks are one
/// thread-specific read; an unnamed one never reads its name again.
///
/// The labels are libdispatch's, not API (risk 6 of plans/cmux-next/chrome-parity/p02-threads.md; task 305
/// checks them on macOS 14 and 15).
///
/// The raw values are the names `debug.blocking` and the hang reports use, so they never change.
public enum BlockingContext: String, Sendable, CaseIterable {
    /// The main thread: blocking is a violation (`CMUX_BLOCKING_TRAP=1` traps in Debug).
    case main
    /// The Swift cooperative pool or a GCD root queue (`Task.detached`, an actor, `DispatchQueue.global`):
    /// threads shared by every task, about one per core, so one blocking call stalls the tasks queued behind it.
    /// Blocking is a violation, recorded (`CMUX_BLOCKING_TRAP_POOL=1` traps in Debug).
    case pool
    /// A slot of a `BackgroundWork` lane that may block (`.files`, `.system`), Chrome's `MayBlock()` task without
    /// `WithBaseSyncPrimitives()`: a wait on the disk, a socket or a process is allowed; a wait for another thread
    /// or process to act (``BlockingKind/isSyncPrimitive``) is a ``laneSync`` violation.
    case lane
    /// A named queue or a registered thread that owns its work: blocking and sync primitives allowed.
    case dedicated
    /// A slot of BackgroundWork's `.cpu` lane, Chrome's task without `MayBlock()`: the lane is sized to the cores,
    /// so a blocking call holds a core's slot idle. Blocking is a ``BlockingKind/wrongLane`` violation, recorded
    /// and never a trap; the fix is to run the job on `.files` or `.system`.
    case cpuLane = "cpu-lane"
    /// Where a sync primitive (``BlockingKind/isSyncPrimitive``: a semaphore, a `DispatchQueue.sync`, a contended
    /// ``Mutex`` past ``BlockingKind/lockWaitLimitNanos``, a synchronous reply) in a ``lane`` item is recorded. The
    /// slot then waits for other work instead of doing its own, and lane items waiting on each other can hold every
    /// slot (Chrome's `ScopedDisallowBaseSyncPrimitives`, base/threading/thread_restrictions.h). Recorded with the
    /// seam's own kind, never a trap; the fix is an `await` on the awaited work, or a dedicated thread. No thread is
    /// in this context: the thread is ``lane``, and this names its sync-primitive sites.
    case laneSync = "lane-sync"

    /// What a thread declares itself for the length of a ``BlockingContext/run(as:_:)`` scope. Internal to this
    /// module: other modules mark only a lane (``runAsLane(_:)``, ``runAsCPULane(_:)``); dedicated comes from
    /// ``allowBlocking(_:_:)``
    /// (a reviewed reason) and from a named thread, never from a bare mark.
    @usableFromInline enum Mark: UInt, Sendable {
        /// A `BackgroundWork` lane slot runs its item (`LaneScheduler`): may block, sync primitives not allowed.
        case lane = 1
        /// A named thread, or ``allowBlocking(_:_:)`` running its body off the main thread: may block and wait
        /// on sync primitives.
        case dedicated = 2
        /// A slot of the `.cpu` lane runs its item (`LaneScheduler`).
        case cpuLane = 3

        /// The context the mark puts the thread in.
        var context: BlockingContext {
            switch self {
            case .lane: .lane
            case .dedicated: .dedicated
            case .cpuLane: .cpuLane
            }
        }
    }

    /// Runs `body`, one `BackgroundWork` lane item, with the calling thread marked ``lane`` (Chrome's `MayBlock()`
    /// task, base/task/thread_pool/task_tracker.cc): its checked blocking calls are allowed, except a sync
    /// primitive (``BlockingKind/isSyncPrimitive``), which records a ``laneSync`` site. Only `LaneScheduler` calls
    /// it, around each item on a lane slot. In Release it only runs `body`.
    ///
    /// ```swift
    /// slot.async { BlockingContext.runAsLane { job.execute() } }
    /// ```
    ///
    /// - Parameter body: The lane item.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws.
    package static func runAsLane<Result, Failure: Error>(_ body: () throws(Failure) -> Result) throws(Failure) -> Result {
        try run(as: .lane, body)
    }

    /// Runs `body`, one item of BackgroundWork's `.cpu` lane, with the calling thread marked ``cpuLane`` (Chrome's
    /// task without `MayBlock()`, which `TaskTracker::RunTask` runs under `ScopedDisallowBlocking`): in Debug and
    /// bench-checks builds a checked blocking call in it records a ``BlockingKind/wrongLane`` site. Only
    /// `LaneScheduler` calls it. In Release it only runs `body`.
    ///
    /// - Parameter body: The lane item.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws.
    package static func runAsCPULane<Result, Failure: Error>(
        _ body: () throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try run(as: .cpuLane, body)
    }

    /// Runs `body` with the calling thread marked `mark`: a checked blocking call in it is classified by the
    /// mark, not by its queue's label (an inner scope wins until it returns). Off the main thread only; the main
    /// thread is always ``main``. In Release it only runs `body`.
    ///
    /// - Parameters:
    ///   - mark: What the thread is while `body` runs.
    ///   - body: The work.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws.
    @usableFromInline static func run<Result, Failure: Error>(
        as mark: Mark, _ body: () throws(Failure) -> Result
    ) throws(Failure) -> Result {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        let previous = BlockingThreadFlags.load()
        BlockingThreadFlags.store(previous.marked(mark))
        defer { BlockingThreadFlags.store(previous) }
        return try body()
        #else
        return try body()
        #endif
    }
}

#if DEBUG || CMUX_BLOCKING_CHECKS
extension BlockingContext {
    /// The context of the calling thread.
    static func current() -> BlockingContext {
        pthread_main_np() != 0 ? .main : offMainThread()
    }

    /// The context in which a `kind` blocking call on the calling thread, which is not the main thread, is a
    /// violation (the checks' off-main path): ``pool`` or ``cpuLane`` for any kind, ``laneSync`` for a sync
    /// primitive on a ``lane``; nil for any other call on a lane and for every call on a dedicated thread.
    ///
    /// - Parameter kind: What the call waits on.
    @usableFromInline
    static func offMainViolation(_ kind: BlockingKind) -> BlockingContext? {
        switch offMainThread() {
        case .pool: .pool
        case .cpuLane: .cpuLane
        case .lane: kind.isSyncPrimitive ? .laneSync : nil
        case .main, .dedicated, .laneSync: nil
        }
    }

    /// Where a ``Mutex`` wait past ``BlockingKind/lockWaitLimitNanos`` on the calling thread, which is not the
    /// main thread, is recorded: ``laneSync`` in a ``lane`` item, ``cpuLane`` (as ``BlockingKind/wrongLane``, the
    /// seam kind ``BlockingKind/lockWait``) in a `.cpu` lane item, as ``offMainViolation(_:)`` places every other
    /// sync primitive there; nil anywhere else (the pool's lock waits are not timed). One thread-specific read.
    static func laneLockWaitViolation() -> BlockingContext? {
        switch BlockingThreadFlags.load().mark {
        case .lane: .laneSync
        case .cpuLane: .cpuLane
        case .dedicated, nil: nil
        }
    }

    /// The context of a thread that is not the main thread. A marked thread (a lane, an allowance, a named
    /// thread after its first check) is one thread-specific read; an unmarked one adds the label read and one
    /// prefix compare. A root label on a thread not yet checked reads the thread name once.
    static func offMainThread() -> BlockingContext {
        let flags = BlockingThreadFlags.load()
        if let mark = flags.mark { return mark.context }
        // SAFETY: dispatch_queue_get_label(NULL) returns the current queue's label, a NUL-terminated string the queue
        // owns while this thread runs on it (an empty one when the queue has none); isPoolLabel reads it only during
        // the call.
        guard unsafe isPoolLabel(__dispatch_queue_get_label(nil)) else { return .dedicated }
        if flags.isUnnamed { return .pool }
        guard isNamedThread() else {
            BlockingThreadFlags.store(flags.withUnnamed())
            return .pool
        }
        BlockingThreadFlags.store(flags.marked(.dedicated))
        return .dedicated
    }

    /// Whether a dispatch queue label names a shared pool: a GCD root queue, the cooperative pool's included
    /// (`com.apple.root.`; `strncmp` stops at the label's end, so a shorter label is no match).
    static func isPoolLabel(_ label: UnsafePointer<CChar>) -> Bool {
        let root: StaticString = "com.apple.root."
        // SAFETY: utf8Start is the literal's static storage of utf8CodeUnitCount bytes, viewed as CChar (the same
        // size) for the closure; strncmp reads at most that many bytes of each string and stops at `label`'s NUL,
        // and the caller lends `label` for this call.
        return unsafe root.utf8Start.withMemoryRebound(to: CChar.self, capacity: root.utf8CodeUnitCount) { bytes in
            unsafe strncmp(label, bytes, root.utf8CodeUnitCount) == 0
        }
    }

    /// Whether the calling thread has a pthread name: a `Thread` cmux made (pool workers have none).
    static func isNamedThread() -> Bool {
        // SAFETY: a 64-byte scratch buffer that lives only for the closure; pthread_getname_np writes at most
        // buffer.count bytes into it, NUL-terminated, and the first byte is read only after it succeeded.
        unsafe withUnsafeTemporaryAllocation(of: CChar.self, capacity: 64) { buffer in
            guard let base = unsafe buffer.baseAddress else { return false }
            return unsafe pthread_getname_np(pthread_self(), base, buffer.count) == 0 && base.pointee != 0
        }
    }
}

/// The calling thread's detector state in one thread-specific word: its ``BlockingContext/Mark`` (low two
/// bits), whether a timed pool call is open on it (so a call inside one counts without time, as on the main
/// thread), and whether a check already found it has no pthread name.
struct BlockingThreadFlags {
    var rawValue: UInt

    private static let markBits: UInt = 0b11
    private static let timedCallBit: UInt = 0b100
    private static let unnamedBit: UInt = 0b1000

    /// The thread-specific key; nil when the process has no key left (no thread is marked then, and calls are
    /// classified by their queue label alone).
    private static let key: pthread_key_t? = {
        var key = pthread_key_t()
        // SAFETY: pthread_key_create writes one key into `key`, a local; no destructor (nil).
        return unsafe pthread_key_create(&key, nil) == 0 ? key : nil
    }()

    init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    /// The calling thread's flags.
    static func load() -> BlockingThreadFlags {
        guard let key else { return BlockingThreadFlags(rawValue: 0) }
        // SAFETY: the thread's value for `key` is never dereferenced: store keeps the flags word in the pointer's
        // bits, and this reads the bits back.
        return BlockingThreadFlags(rawValue: unsafe UInt(bitPattern: pthread_getspecific(key)))
    }

    /// Sets the calling thread's flags.
    static func store(_ flags: BlockingThreadFlags) {
        guard let key else { return }
        // SAFETY: the flags word travels in the pointer's bits and is never dereferenced (load reads the bits back);
        // no destructor is registered for the key, so nothing frees it.
        unsafe pthread_setspecific(key, UnsafeRawPointer(bitPattern: flags.rawValue))
    }

    var mark: BlockingContext.Mark? {
        BlockingContext.Mark(rawValue: rawValue & Self.markBits)
    }

    func marked(_ mark: BlockingContext.Mark) -> BlockingThreadFlags {
        BlockingThreadFlags(rawValue: rawValue & ~Self.markBits | mark.rawValue)
    }

    var timedCallOpen: Bool { rawValue & Self.timedCallBit != 0 }

    func withTimedCallOpen() -> BlockingThreadFlags {
        BlockingThreadFlags(rawValue: rawValue | Self.timedCallBit)
    }

    /// A check found the thread has no pthread name (a pool worker): later checks skip the name read.
    var isUnnamed: Bool { rawValue & Self.unnamedBit != 0 }

    func withUnnamed() -> BlockingThreadFlags {
        BlockingThreadFlags(rawValue: rawValue | Self.unnamedBit)
    }
}
#endif
