import Foundation

extension MainTurnMeter {
    /// The meter's counters: totals per kind of time, the turn and task histograms (fixed buckets,
    /// ``bucketEdges``) and the longest unattributed turns. A value: the main thread only copies it,
    /// and a report folds the percentiles from it on any thread.
    public nonisolated struct Snapshot: Sendable, Equatable {
        /// Busy turns measured, and how many ran inside a nested run loop.
        public var turns = 0
        /// Busy turns that ran inside a nested run loop (menu tracking, a modal panel, a live resize).
        public var nestedTurns = 0
        /// Turns longer than ``MainTurnMeter/stallNanos`` (each wrote `stall.main_turn`).
        public var turnsOverStall = 0
        /// The turns' busy time in all, and its split, in nanoseconds.
        public var busyNanos: UInt64 = 0
        /// Busy time in scheduled tasks (``MainFrameBudget``'s), in nanoseconds.
        public var scheduledNanos: UInt64 = 0
        /// Busy time in input dispatch, in nanoseconds.
        public var inputNanos: UInt64 = 0
        /// Busy time in render passes (layout, display, commit), in nanoseconds.
        public var renderNanos: UInt64 = 0
        /// Busy time no scheduled task, input dispatch or render pass explains, in nanoseconds.
        public var unattributedNanos: UInt64 = 0
        /// The longest busy turn, in nanoseconds.
        public var maxTurnNanos: UInt64 = 0
        /// Turns per bucket of ``bucketEdges`` (the last bucket: longer than the last edge).
        public var turnBuckets = [UInt32](repeating: 0, count: Snapshot.bucketEdges.count + 1)
        /// Scheduled tasks measured (each task's own time), the longest, and per bucket.
        public var tasks = 0
        /// The longest scheduled task, in nanoseconds.
        public var maxTaskNanos: UInt64 = 0
        /// Scheduled tasks per bucket of ``bucketEdges`` (the last bucket: longer than the last edge).
        public var taskBuckets = [UInt32](repeating: 0, count: Snapshot.bucketEdges.count + 1)
        /// The slots of the turns with the most unattributed time, in no order (empty slots are
        /// zero); ``longestUnattributed`` sorts them.
        public var topUnattributed = [TopTurn](repeating: TopTurn(), count: MainTurnMeter.topCount)
        /// The turns that ran the budgeted scheduler's display tick (``TurnKind/tick``), and how many
        /// of them ran a budgeted task too: the in-tick placement's batch, zero after commit.
        public var tickTurns = KindTurns()
        public var tickTurnsWithBudgetedTasks = 0
        /// The after-commit placement's budget turns (``TurnKind/budget``).
        public var budgetTurns = KindTurns()

        /// One kind's turns: how many, the longest, and per bucket of ``bucketEdges``.
        public nonisolated struct KindTurns: Sendable, Equatable {
            public var count = 0
            public var maxNanos: UInt64 = 0
            public var buckets = [UInt32](repeating: 0, count: Snapshot.bucketEdges.count + 1)

            mutating func record(_ nanos: UInt64, bucket: Int) {
                count += 1
                maxNanos = max(maxNanos, nanos)
                buckets[bucket] &+= 1
            }
        }

        /// The buckets' upper edges in nanoseconds: 4 ms (the turn target) and 16.7 ms (a 60 Hz frame)
        /// are edges, so the share of turns under each is exact.
        public static let bucketEdges: [UInt64] = [
            125_000, 250_000, 500_000, 1_000_000, 2_000_000, 4_000_000, 8_000_000, 16_666_667, 33_333_333,
            50_000_000, 100_000_000, 250_000_000, 1_000_000_000,
        ]

        /// The bucket `nanos` falls in.
        public static func bucket(_ nanos: UInt64) -> Int {
            var index = 0
            while index < bucketEdges.count, nanos > bucketEdges[index] { index += 1 }
            return index
        }

        /// The kept turns with unattributed time, longest first (a report's fold, off the main thread).
        public var longestUnattributed: [TopTurn] {
            topUnattributed.filter { $0.unattributedNanos > 0 }.sorted { $0.unattributedNanos > $1.unattributedNanos }
        }

        /// Unattributed time over busy time (0 with no busy time).
        public var unattributedShare: Double {
            busyNanos == 0 ? 0 : Double(unattributedNanos) / Double(busyNanos)
        }

        /// The `quantile` (0...1) of a histogram, as its bucket's upper edge; the last bucket reports
        /// `max`, and an empty histogram 0.
        public static func percentile(_ quantile: Double, of buckets: [UInt32], max: UInt64) -> UInt64 {
            let total = buckets.reduce(0) { $0 + UInt64($1) }
            guard total > 0 else { return 0 }
            let rank = UInt64((Double(total) * quantile).rounded(.up))
            var seen: UInt64 = 0
            for (index, count) in buckets.enumerated() {
                seen += UInt64(count)
                if seen >= Swift.max(rank, 1) { return index < bucketEdges.count ? Swift.min(bucketEdges[index], max) : max }
            }
            return max
        }
    }

    /// One measured turn: its busy time, its split, when it ended and whether it ran inside a nested
    /// run loop.
    public nonisolated struct TopTurn: Sendable, Equatable {
        /// The turn's busy time, in nanoseconds.
        public var turnNanos: UInt64 = 0
        /// The part nothing measured explains, in nanoseconds.
        public var unattributedNanos: UInt64 = 0
        /// The part in scheduled tasks, in nanoseconds.
        public var scheduledNanos: UInt64 = 0
        /// The part in input dispatch, in nanoseconds.
        public var inputNanos: UInt64 = 0
        /// The part in render passes, in nanoseconds.
        public var renderNanos: UInt64 = 0
        /// The turn's end (`CLOCK_UPTIME_RAW` nanoseconds).
        public var endNanos: UInt64 = 0
        /// Whether it ran inside a nested run loop.
        public var nested = false

        /// A turn from its parts (the meter records them; tests build them).
        public init(turnNanos: UInt64 = 0, unattributedNanos: UInt64 = 0, scheduledNanos: UInt64 = 0, inputNanos: UInt64 = 0,
                    renderNanos: UInt64 = 0, endNanos: UInt64 = 0, nested: Bool = false) {
            self.turnNanos = turnNanos
            self.unattributedNanos = unattributedNanos
            self.scheduledNanos = scheduledNanos
            self.inputNanos = inputNanos
            self.renderNanos = renderNanos
            self.endNanos = endNanos
            self.nested = nested
        }

        /// The `stall.main_turn` record's `arg0`: the turn in microseconds, bit 63 set for a nested turn.
        var ringArg0: UInt64 {
            min(turnNanos / 1_000, (1 << 63) - 1) | (nested ? 1 << 63 : 0)
        }

        /// The `stall.main_turn` record's `arg1`: scheduled, render, input and unattributed time, 16 bits
        /// each from bit 0, in 100 µs units (0xFFFF for 6.5 s or more).
        var ringArg1: UInt64 {
            Self.tenths(scheduledNanos) | Self.tenths(renderNanos) << 16 | Self.tenths(inputNanos) << 32
                | Self.tenths(unattributedNanos) << 48
        }

        private static func tenths(_ nanos: UInt64) -> UInt64 { min(nanos / 100_000, 0xFFFF) }
    }
}
