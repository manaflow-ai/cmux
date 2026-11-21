extension MainFrameBudget {
    /// Owner slots of the always-on task record. An owner takes one at its first recorded task (not when its name is
    /// interned on the board: the bound actions intern more names than this and record no task); the owners that run
    /// after every slot is taken share one slot named ``overflowOwnerName``. Sized for the owners that can run: about
    /// 400 observation sites (each `ObservationStream` is one), the frame and batch queues, and each control method a
    /// script calls.
    public static let ownerTimesCapacity = 1024
    /// The name of the slot that the owners share which run after ``ownerTimesCapacity`` others.
    public static let overflowOwnerName = "(other owners)"

    /// One owner's tasks since launch or the last ``resetStats()``: count, tasks over 8 ms, total, max (exact) and
    /// p50 / p95 / p99 (log bucket edges, at most a quarter above the true value, never past the max).
    public struct OwnerTimes: Sendable, Equatable {
        public var owner: String
        public var count: Int
        public var over8msCount: Int
        public var totalNanos: UInt64
        public var maxNanos: UInt64
        public var p50Nanos: UInt64
        public var p95Nanos: UInt64
        public var p99Nanos: UInt64
    }

    /// Every owner with tasks in the record, largest total time first (main-thread-scheduling.md G3, read by
    /// `debug.main_budget`; takes the board's owners lock once per owner, so call it from a report, never per task).
    public var ownerTimes: [OwnerTimes] {
        taskTimes.slots().map { slot in
            OwnerTimes(owner: slot.index == 0 ? Self.overflowOwnerName : board.name(of: slot.owner), count: slot.count,
                       over8msCount: slot.failures, totalNanos: slot.totalNanos, maxNanos: slot.maxNanos, p50Nanos: slot.p50Nanos,
                       p95Nanos: slot.p95Nanos, p99Nanos: slot.p99Nanos)
        }
        .sorted { $0.totalNanos != $1.totalNanos ? $0.totalNanos > $1.totalNanos : $0.owner < $1.owner }
    }
}
