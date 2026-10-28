/// How many ``BlockingLane/files`` items of each ``WorkPriority`` run at once.
///
/// Each priority has slots of its own, so a best-effort write never holds the slot a user-blocking read
/// needs, and one slow read no longer holds every later read of its priority. Chrome runs file work on
/// its thread pool next to the other tasks of the same priority class, several at once
/// (base/task/thread_pool/thread_group_impl.cc), and best-effort tasks at most `kMaxBestEffortTasks` (2)
/// at once (base/task/thread_pool/thread_pool_impl.cc); the daemon's files lane (`cmux_threads::work`)
/// has the same 4/3/2/1. Work that must run in order goes through a ``WorkSequence``, never through a
/// width of 1.
public struct FilesLaneWidths: Sendable, Equatable {
    /// Items of ``WorkPriority/userBlocking`` that may run at once.
    public var userBlocking: Int
    /// Items of ``WorkPriority/userVisible`` that may run at once.
    public var userVisible: Int
    /// Items of ``WorkPriority/bestEffort`` that may run at once.
    public var bestEffort: Int
    /// Items of ``WorkPriority/idle`` that may run at once.
    public var idle: Int

    /// Each width is at least 1.
    public init(userBlocking: Int, userVisible: Int, bestEffort: Int, idle: Int) {
        self.userBlocking = max(1, userBlocking)
        self.userVisible = max(1, userVisible)
        self.bestEffort = max(1, bestEffort)
        self.idle = max(1, idle)
    }

    /// The app's lane: 4 user-blocking, 3 user-visible, 2 best-effort and 1 idle item at once.
    public static let standard = FilesLaneWidths(userBlocking: 4, userVisible: 3, bestEffort: 2, idle: 1)

    /// One item of each priority at a time: for tests that hold a slot so that the next item queues.
    public static let serial = FilesLaneWidths(userBlocking: 1, userVisible: 1, bestEffort: 1, idle: 1)

    /// How many items at `priority` run at once.
    public func width(_ priority: WorkPriority) -> Int {
        switch priority {
        case .userBlocking: userBlocking
        case .userVisible: userVisible
        case .bestEffort: bestEffort
        case .idle: idle
        }
    }
}
