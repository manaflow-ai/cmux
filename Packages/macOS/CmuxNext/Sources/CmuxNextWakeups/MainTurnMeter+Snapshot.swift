import Foundation

extension MainTurnMeter {
    /// The meter's counters: totals per kind of time, the turn and task histograms (fixed buckets,
    /// ``bucketEdges``) and the longest unattributed turns. A value: a report folds the percentiles
    /// from it on any thread.
    public struct Snapshot: Sendable, Equatable {
        /// Busy turns measured, and how many ran inside a nested run loop.
        public var turns = 0
        public var nestedTurns = 0
        /// Turns longer than ``MainTurnMeter/stallNanos`` (each emitted `stall.main_turn`).
        public var turnsOverStall = 0
        /// The turns' busy time in all, and its split, in nanoseconds.
        public var busyNanos: UInt64 = 0
        public var scheduledNanos: UInt64 = 0
        public var inputNanos: UInt64 = 0
        public var renderNanos: UInt64 = 0
        public var unattributedNanos: UInt64 = 0
        public var maxTurnNanos: UInt64 = 0
        /// Turns per bucket of ``bucketEdges`` (the last bucket: longer than the last edge).
        public var turnBuckets = [UInt32](repeating: 0, count: Snapshot.bucketEdges.count + 1)
        /// Scheduled tasks measured (each task's own time), the longest, and per bucket.
        public var tasks = 0
        public var maxTaskNanos: UInt64 = 0
        public var taskBuckets = [UInt32](repeating: 0, count: Snapshot.bucketEdges.count + 1)
        /// The turns with the most unattributed time; from ``MainTurnMeter/snapshot()``, longest first.
        public var topUnattributed = [TopTurn](repeating: TopTurn(), count: MainTurnMeter.topCount)

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
    public struct TopTurn: Sendable, Equatable {
        public var turnNanos: UInt64 = 0
        public var unattributedNanos: UInt64 = 0
        public var scheduledNanos: UInt64 = 0
        public var inputNanos: UInt64 = 0
        public var renderNanos: UInt64 = 0
        /// The turn's end (`CLOCK_UPTIME_RAW` nanoseconds).
        public var endNanos: UInt64 = 0
        public var nested = false

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

        /// The `stall.main_turn` message: `ms=<turn> scheduled_ms= render_ms= input_ms= unattributed_ms= nested=`.
        var message: String {
            "ms=\(Self.ms(turnNanos)) scheduled_ms=\(Self.ms(scheduledNanos)) render_ms=\(Self.ms(renderNanos)) "
                + "input_ms=\(Self.ms(inputNanos)) unattributed_ms=\(Self.ms(unattributedNanos)) nested=\(nested ? 1 : 0)"
        }

        private static func ms(_ nanos: UInt64) -> String { String(format: "%.2f", Double(nanos) / 1_000_000) }
    }
}
