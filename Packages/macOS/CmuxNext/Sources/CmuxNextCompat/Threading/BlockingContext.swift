internal import Darwin

/// Where a blocking call runs, as the blocking detector judges it.
///
/// Chrome keeps its thread restrictions per thread and sets them per task: a thread pool worker runs a task
/// without the `MayBlock` trait inside `ScopedDisallowBlocking` (`TaskTracker::RunTask`,
/// base/task/thread_pool/task_tracker.cc), so a blocking call in it fails `AssertBlockingAllowed`
/// (base/threading/thread_restrictions.cc). BackgroundWork does the same: each lane job runs with its thread
/// marked as its lane's context (``whileCurrent(_:)``), and a blocking seam in a ``cpuLane`` job records a
/// ``BlockingKind/wrongLane`` site. Debug and bench builds only: in Release no thread is marked and the off-main
/// check is compiled out.
///
/// ```swift
/// context.whileCurrent { job.execute() }   // LaneScheduler, around each job of its lane
/// ```
public enum BlockingContext: Sendable, CaseIterable, CustomStringConvertible {
    /// The main thread: a blocking call is a violation (``blockingCall(_:fileID:line:_:)``).
    case main
    /// A job of a lane for work that may block (BackgroundWork's `.files` and `.system` lanes).
    case lane
    /// A job of the lane for CPU-bound work (BackgroundWork's `.cpu` lane), sized to the cores: a blocking call
    /// there holds a core's slot idle, so it is a ``BlockingKind/wrongLane`` violation. Move the job to `.files`
    /// or `.system`.
    case cpuLane

    public var description: String {
        switch self {
        case .main: "main"
        case .lane: "lane"
        case .cpuLane: "cpu-lane"
        }
    }

    /// The calling thread's context: ``main`` on the main thread, else the lane of the job running on it, else
    /// nil. In Release no thread is marked, so off the main thread it is nil.
    public static var current: BlockingContext? {
        if pthread_main_np() != 0 { return .main }
        #if DEBUG || CMUX_BLOCKING_CHECKS
        return threadMark
        #else
        return nil
        #endif
    }

    /// Runs `body` with the calling thread marked as this context, then restores the previous mark. ``lane`` and
    /// ``cpuLane`` mark the thread; ``main`` clears the mark for `body`. In Release it is `body` alone.
    ///
    /// - Parameter body: The lane job.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws.
    @inlinable @inline(__always)
    public func whileCurrent<Result, Failure: Error>(_ body: () throws(Failure) -> Result) throws(Failure) -> Result {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        let previous = Self.threadMark
        Self.setThreadMark(self)
        defer { Self.setThreadMark(previous) }
        #endif
        return try body()
    }

    #if DEBUG || CMUX_BLOCKING_CHECKS
    /// The off-main part of ``blockingCall(_:fileID:line:_:)``: a seam in a ``cpuLane`` job records a
    /// ``BlockingKind/wrongLane`` site at the caller's line. On any other thread it is one thread-local read and
    /// one branch.
    @inlinable @inline(__always)
    static func checkOffMain(_ kind: BlockingKind, fileID: StaticString, line: UInt) {
        if threadMark == .cpuLane {
            BlockingViolationTable.blockedInWrongLane(kind, fileID: fileID, line: line)
        }
    }

    /// The thread-local slot of the mark; nil when the key could not be made (then no thread is marked).
    private static let markKey: pthread_key_t? = {
        var key = pthread_key_t()
        return pthread_key_create(&key, nil) == 0 ? key : nil
    }()

    /// The calling thread's mark. The slot holds 0 (none), 1 (``lane``) or 2 (``cpuLane``) as its pointer
    /// value, so marking a thread allocates nothing and needs no destructor.
    @usableFromInline static var threadMark: BlockingContext? {
        guard let key = markKey else { return nil }
        switch UInt(bitPattern: pthread_getspecific(key)) {
        case 1: return .lane
        case 2: return .cpuLane
        default: return nil
        }
    }

    @usableFromInline static func setThreadMark(_ mark: BlockingContext?) {
        guard let key = markKey else { return }
        let slot: UInt = switch mark {
        case .some(.lane): 1
        case .some(.cpuLane): 2
        case .some(.main), .none: 0
        }
        _ = pthread_setspecific(key, UnsafeRawPointer(bitPattern: slot))
    }
    #endif
}
