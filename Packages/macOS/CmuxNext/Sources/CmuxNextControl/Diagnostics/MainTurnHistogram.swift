public import CmuxNextSettings
import CmuxNextCompat

/// A duration histogram at Chrome's resolution: exponential buckets from 50 µs to 10 s, each edge at
/// most 1.2 times the one below (Chromium's `UMA_HISTOGRAM_CUSTOM_TIMES` buckets,
/// base/metrics/histogram.cc `Histogram::InitializeBucketRanges`, exponential from min to max). A 10 %
/// shift moves a sample to the next bucket, which log2 edges (2, 4, 8 ms) cannot show: 3.6 and 4.4 ms
/// count in different buckets.
///
/// The counters are relaxed atomics in one fixed allocation (each bucket's word, then the maximum's,
/// addressed through ``AtomicPointerSlot``, like Chromium's flat `SampleVector` counts): recording takes
/// no lock, allocates nothing and reads no clock (the caller passes a duration from stamps it already
/// took). One writer (the main thread) and any reader; a read while the writer counts may miss that sample.
///
/// The watchdog keeps two (``MainThreadWatchdog/turnHistogram``, ``MainThreadWatchdog/inputQueueHistogram``),
/// served by `debug.hangs` `turn_histogram`.
public final class MainTurnHistogram: Sendable {
    /// The smallest and largest edges: a sample under 50 µs counts in bucket 0, one of 10 s or more in
    /// the last bucket.
    public static let minimumNanos: UInt64 = 50_000
    public static let maximumNanos: UInt64 = 10_000_000_000
    /// The ratio of each edge to the one below (the last step is shorter, so it ends at 10 s).
    public static let ratio = 1.2

    /// The bucket edges in nanoseconds, increasing: bucket 0 counts samples below `edgesNanos[0]`,
    /// bucket `i` counts samples in `edgesNanos[i - 1] ..< edgesNanos[i]`, and the last bucket counts
    /// samples of `edgesNanos.last` or more. 68 edges, 69 buckets.
    public static let edgesNanos: [UInt64] = {
        var edges: [UInt64] = []
        var edge = Double(MainTurnHistogram.minimumNanos)
        while edge < Double(MainTurnHistogram.maximumNanos) {
            edges.append(UInt64(exactly: edge.rounded()) ?? MainTurnHistogram.maximumNanos)
            edge *= MainTurnHistogram.ratio
        }
        edges.append(MainTurnHistogram.maximumNanos)
        return edges
    }()

    /// Buckets including the underflow and overflow ones.
    public static let bucketCount = edgesNanos.count + 1
    /// The allocation's words: one per bucket, then the maximum.
    private static let wordCount = bucketCount + 1

    /// `wordCount` zeroed words, 8-byte aligned; allocated once, never resized.
    nonisolated(unsafe) private let words: UnsafeMutablePointer<UInt64> // crash-allow: one fixed allocation; every access after init is an atomic operation (AtomicPointerSlot)

    public init() {
        // SAFETY: a fresh allocation of wordCount words, every one initialized to zero here; it is freed once, in
        // deinit, and never resized.
        words = unsafe UnsafeMutablePointer<UInt64>.allocate(capacity: Self.wordCount)
        unsafe words.initialize(repeating: 0, count: Self.wordCount)
    }

    deinit {
        // SAFETY: the allocation of init, wordCount initialized words; nothing else holds `self` any more.
        unsafe words.deinitialize(count: Self.wordCount)
        unsafe words.deallocate()
    }

    /// The word `index`: a bucket (under bucketCount, as bucket(forNanos:) returns and the reads loop over) or the
    /// maximum (bucketCount).
    @inline(__always)
    private func slot(_ index: Int) -> AtomicPointerSlot {
        assert(index >= 0 && index < Self.wordCount)
        // SAFETY: index < wordCount (see above), so the word is inside the allocation, which lives as long as
        // `self`; allocate aligns it for UInt64.
        return unsafe AtomicPointerSlot(words + index)
    }

    @inline(__always)
    private var maximum: AtomicPointerSlot { slot(Self.bucketCount) }

    /// The bucket `nanos` counts in: the number of edges at or below it.
    public static func bucket(forNanos nanos: UInt64) -> Int {
        edgesNanos.firstIndex { nanos < $0 } ?? edgesNanos.count
    }

    /// Counts one sample of `nanos`: two relaxed atomic adds and, for a new maximum, a compare-exchange.
    // perf-hot: 1us frame-tick
    public func record(nanos: UInt64) {
        slot(Self.bucket(forNanos: nanos)).add(1, ordering: .relaxed)
        var seen = maximum.load(ordering: .relaxed)
        while nanos > seen {
            let (exchanged, original) = maximum.compareExchange(expected: seen, desired: nanos, ordering: .relaxed)
            if exchanged { break }
            seen = original
        }
    }

    /// The counts now (allocates; read off the hot path).
    public func snapshot() -> Snapshot {
        Snapshot(counts: (0..<Self.bucketCount).map { slot($0).load(ordering: .relaxed) }, maxNanos: maximum.load(ordering: .relaxed))
    }

    /// Zeroes every bucket and the maximum (`debug.hangs clear`).
    public func reset() {
        for index in 0..<Self.wordCount { slot(index).store(0, ordering: .relaxed) }
    }

    /// One read of a ``MainTurnHistogram``.
    public struct Snapshot: Sendable, Equatable {
        /// The count per bucket (``MainTurnHistogram/bucketCount`` entries).
        public var counts: [UInt64]
        /// The largest sample counted.
        public var maxNanos: UInt64

        public init(counts: [UInt64], maxNanos: UInt64) {
            self.counts = counts
            self.maxNanos = maxNanos
        }

        public var count: UInt64 { counts.reduce(0) { $0 &+ $1 } }

        /// The `quantile` (0...1) in nanoseconds, interpolated by rank inside the bucket the rank falls
        /// in (Chromium's percentile from a bucketed histogram), never above the largest sample. The
        /// estimate and the true value share a bucket, so they differ by less than the bucket's 20 %.
        /// 0 for an empty histogram.
        public func percentile(_ quantile: Double) -> UInt64 {
            let total = count
            guard total > 0 else { return 0 }
            let rank = max(1, UInt64(exactly: (Double(total) * min(max(quantile, 0), 1)).rounded(.up)) ?? total)
            // Each bucket's bounds: 0 below the first edge, the largest sample above the last one.
            let lows = [0] + MainTurnHistogram.edgesNanos
            let highs = MainTurnHistogram.edgesNanos + [maxNanos]
            var seen: UInt64 = 0
            for (bucketCount, (low, edge)) in zip(counts, zip(lows, highs)) where bucketCount > 0 {
                guard seen + bucketCount >= rank else {
                    seen += bucketCount
                    continue
                }
                let high = min(edge, maxNanos)
                guard high > low else { return min(low, maxNanos) }
                let fraction = Double(rank - seen) / Double(bucketCount)
                return low + (UInt64(exactly: (Double(high - low) * fraction).rounded()) ?? 0)
            }
            return maxNanos
        }

        /// `count`, `buckets` (one per bucket of ``MainTurnHistogram/edgesNanos``), `p50_ms`, `p95_ms`,
        /// `p99_ms` and `max_ms`.
        public var json: JSONValue {
            .object([
                "count": JSONValue(Int(clamping: count)),
                "buckets": .array(counts.map { JSONValue(Int(clamping: $0)) }),
                "p50_ms": .number(Self.milliseconds(percentile(0.50))),
                "p95_ms": .number(Self.milliseconds(percentile(0.95))),
                "p99_ms": .number(Self.milliseconds(percentile(0.99))),
                "max_ms": .number(Self.milliseconds(maxNanos)),
            ])
        }

        private static func milliseconds(_ nanos: UInt64) -> Double { Double(nanos) / 1_000_000 }
    }
}

/// The main-turn and input-queueing histograms: a turn is a run-loop wake to
/// the end of its before-waiting phase, the heartbeat's own stamps; an input's queueing is its OS event
/// time to its first dispatch (`sendEvent`), the queue part of Chromium's `kQueueAndExecution`
/// (content/browser/scheduler/responsiveness/calculator.h).
extension MainThreadWatchdog {
    /// Counts one input's queueing: from `eventTimestamp` (`NSEvent.timestamp`, seconds of
    /// `CLOCK_UPTIME_RAW`) to `dispatchedNanos`, the uptime stamp its dispatch took (the turn meter's
    /// input span begins there), so time spent behind an earlier event's handler counts. An event counts
    /// once: one no newer than the newest counted (a held key replayed, a chord re-sent) counts nothing.
    /// It is also the person's activity for `hang.over250.per_hour` (``MainThreadFieldMetrics``).
    /// Main thread; a timestamp of 0 (no OS time) counts nothing.
    // perf-hot: 1us frame-tick
    public func noteInputDispatch(eventTimestamp: Double, dispatchedNanos: UInt64) {
        guard eventTimestamp > 0, let event = UInt64(exactly: (eventTimestamp * 1_000_000_000).rounded(.down)),
              event > newestQueuedInputNanos.load(ordering: .relaxed) else { return }
        newestQueuedInputNanos.store(event, ordering: .relaxed)
        inputQueueHistogram.record(nanos: dispatchedNanos > event ? dispatchedNanos - event : 0)
        fieldMetrics.inputArrived(atNanos: event)
    }

    /// `debug.hangs` `turn_histogram`: the bucket edges in microseconds, then `main_turn` and
    /// `input_queueing` (``MainTurnHistogram/Snapshot/json``).
    public var turnHistogramJSON: JSONValue {
        .object([
            "edges_us": .array(MainTurnHistogram.edgesNanos.map { JSONValue.number(Double($0) / 1_000) }),
            "main_turn": turnHistogram.snapshot().json,
            "input_queueing": inputQueueHistogram.snapshot().json,
        ])
    }

    /// Zeroes both histograms (`debug.hangs clear`).
    public func resetTurnHistograms() {
        turnHistogram.reset()
        inputQueueHistogram.reset()
    }
}
