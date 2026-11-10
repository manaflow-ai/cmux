extension MainFrameBudget {
    /// Owner slots of the always-on task record; owners interned past it share one slot named ``overflowOwnerName``.
    public static let ownerTimesCapacity = 512
    /// The name of the slot owners past ``ownerTimesCapacity`` share.
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
            OwnerTimes(owner: slot.index == 0 ? Self.overflowOwnerName : board.name(of: UInt32(slot.index)), count: slot.count,
                       over8msCount: slot.failures, totalNanos: slot.totalNanos, maxNanos: slot.maxNanos, p50Nanos: slot.p50Nanos,
                       p95Nanos: slot.p95Nanos, p99Nanos: slot.p99Nanos)
        }
        .sorted { $0.totalNanos != $1.totalNanos ? $0.totalNanos > $1.totalNanos : $0.owner < $1.owner }
    }
}
