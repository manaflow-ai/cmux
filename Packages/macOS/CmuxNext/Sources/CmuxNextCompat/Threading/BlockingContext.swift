#if DEBUG || CMUX_BLOCKING_CHECKS
internal import Darwin
internal import Dispatch
#endif

/// Where a checked blocking call runs, as the blocking detector classifies the calling thread: Chrome's
/// per-thread `ThreadRestrictions`, which disallow blocking on the UI thread and on every pool thread that
/// runs a task without `MayBlock()` (base/task/thread_pool/task_tracker.cc, `RunTask`).
///
/// The detector reads, in order: the main thread; else the thread's own mark (``run(as:_:)``, set by a
/// `BackgroundWork` lane slot or a registered dedicated thread); else the label of the dispatch queue running
/// the call. A GCD root queue (label prefix `com.apple.root.`, which the Swift cooperative pool's labels such as
/// `com.apple.root.user-initiated-qos.cooperative` share) or a cooperative queue (suffix `.cooperative`) is
/// ``pool``; any other queue, a named serial queue included, is ``dedicated``. A thread that runs no queue reads
/// the default root queue's label, so it is ``pool`` unless it has a pthread name (every cmux `Thread` is named:
/// threading-model.md, "Registered threads and queues"; pool workers are not).
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
    /// A `BackgroundWork` lane slot, Chrome's `MayBlock()` task: blocking allowed.
    case lane
    /// A named queue or a registered thread that owns its work: blocking allowed.
    case dedicated

    /// What a thread declares itself for the length of a ``BlockingContext/run(as:_:)`` scope.
    @usableFromInline package enum Mark: UInt, Sendable {
        /// A `BackgroundWork` lane slot runs its item (`LaneScheduler`).
        case lane = 1
        /// A registered dedicated thread runs its loop, or ``allowBlocking(_:_:)`` runs its body off the main
        /// thread.
        case dedicated = 2

        /// The context the mark puts the thread in.
        package var context: BlockingContext {
            switch self {
            case .lane: .lane
            case .dedicated: .dedicated
            }
        }
    }

    /// Runs `body` with the calling thread marked `mark`: a checked blocking call in it is classified by the
    /// mark, not by its queue's label (an inner scope wins until it returns). Off the main thread only; the main
    /// thread is always ``main``. In Release it only runs `body`.
    ///
    /// Only `LaneScheduler` (around each lane item) and registered dedicated threads call it; a mark is not a
    /// way to silence a pool violation (move the work onto `work.run` instead).
    ///
    /// ```swift
    /// slot.async { BlockingContext.run(as: .lane) { job.execute() } }
    /// ```
    ///
    /// - Parameters:
    ///   - mark: What the thread is while `body` runs.
    ///   - body: The work.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws.
    @usableFromInline package static func run<Result, Failure: Error>(
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

    /// Whether the calling thread, which is not the main thread, is a shared pool thread (the checks' off-main
    /// path: a pool call is a violation, every other off-main call is not).
    @usableFromInline
    static func isPoolThread() -> Bool {
        offMainThread() == .pool
    }

    /// The context of a thread that is not the main thread. A marked thread is one thread-specific read; an
    /// unmarked one adds the label read and its compare. Only a pool label reads the thread name.
    static func offMainThread() -> BlockingContext {
        if let mark = BlockingThreadFlags.load().mark { return mark.context }
        guard isPoolLabel(__dispatch_queue_get_label(nil)) else { return .dedicated }
        return isNamedThread() ? .dedicated : .pool
    }

    /// Whether a dispatch queue label names a shared pool: a GCD root queue (`com.apple.root.`, a prefix the
    /// cooperative pool's labels share) or a Swift cooperative queue (`.cooperative`).
    static func isPoolLabel(_ label: UnsafePointer<CChar>) -> Bool {
        let root: StaticString = "com.apple.root."
        let cooperative: StaticString = ".cooperative"
        if hasPrefix(label, root) { return true }
        let length = strlen(label)
        guard length >= cooperative.utf8CodeUnitCount else { return false }
        return memcmp(label + (length - cooperative.utf8CodeUnitCount), cooperative.utf8Start,
                      cooperative.utf8CodeUnitCount) == 0
    }

    /// Whether `label` starts with `prefix` (`strncmp` stops at the label's end, so a shorter label is no match).
    private static func hasPrefix(_ label: UnsafePointer<CChar>, _ prefix: StaticString) -> Bool {
        prefix.utf8Start.withMemoryRebound(to: CChar.self, capacity: prefix.utf8CodeUnitCount) { bytes in
            strncmp(label, bytes, prefix.utf8CodeUnitCount) == 0
        }
    }

    /// Whether the calling thread has a pthread name: a `Thread` cmux made (pool workers have none).
    static func isNamedThread() -> Bool {
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: 64) { buffer in
            guard let base = buffer.baseAddress else { return false }
            return pthread_getname_np(pthread_self(), base, buffer.count) == 0 && base.pointee != 0
        }
    }
}

/// The calling thread's detector state in one thread-specific word: its ``BlockingContext/Mark`` (low two
/// bits) and whether a timed pool call is open on it, so a call inside one counts without time, as on the
/// main thread.
struct BlockingThreadFlags {
    var rawValue: UInt

    private static let markBits: UInt = 0b11
    private static let timedCallBit: UInt = 0b100

    /// The thread-specific key; nil when the process has no key left (no thread is marked then, and calls are
    /// classified by their queue label alone).
    private static let key: pthread_key_t? = {
        var key = pthread_key_t()
        return pthread_key_create(&key, nil) == 0 ? key : nil
    }()

    init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    /// The calling thread's flags.
    static func load() -> BlockingThreadFlags {
        guard let key else { return BlockingThreadFlags(rawValue: 0) }
        return BlockingThreadFlags(rawValue: UInt(bitPattern: pthread_getspecific(key)))
    }

    /// Sets the calling thread's flags.
    static func store(_ flags: BlockingThreadFlags) {
        guard let key else { return }
        pthread_setspecific(key, UnsafeRawPointer(bitPattern: flags.rawValue))
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
}
#endif
