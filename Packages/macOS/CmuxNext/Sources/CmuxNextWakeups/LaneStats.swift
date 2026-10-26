import CmuxNextCompat
import Darwin

/// How long one ``BackgroundWork`` lane's items waited for a slot (submit to start) and ran (start to end), per
/// ``WorkPriority``, in every build (Release too): the lane side of Chrome's thread pool latency metrics,
/// `ThreadPool.TaskLatencyMicroseconds.<group>.<priority>` (base/task/thread_pool/task_tracker.cc
/// `TaskTracker::RecordLatencyHistogram`, which counts post to start per priority), plus the run time.
///
/// The buckets are log2 of the duration in 1/1024 ms (``LaneHistogram``), so a millisecond and its doubles are
/// bucket edges. Each counter is one relaxed ``Atomic``, made once at init: ``record(_:waitNanos:runNanos:)``
/// takes no lock, allocates nothing and reads no clock (the lane passes the stamps it took). A read while a lane
/// thread records may miss that item, and ``reset()`` racing a record may keep part of it; both only shift one
/// sample.
final class LaneStats: Sendable {
    /// One counter (an ``Atomic`` cannot sit in an array by itself: it is not copyable).
    private final class Word: Sendable {
        let value = Atomic<UInt64>(0)
    }

    /// Words per histogram: one per bucket, then the sum of the samples in nanoseconds.
    private static let histogramWords = LaneHistogram.bucketCount + 1
    /// Words per priority: the wait histogram, then the run histogram.
    private static let priorityWords = 2 * histogramWords
    private static let wordCount = WorkPriority.allCases.count * priorityWords

    /// `wordCount` counters, by priority, then wait and run, then bucket and sum; never resized.
    private let words: [Word]

    init() {
        words = (0..<Self.wordCount).map { _ in Word() }
    }

    /// The clock the lanes stamp items with by default: `CLOCK_UPTIME_RAW` nanoseconds (`mach_absolute_time`
    /// in nanoseconds), one commpage read with no system call.
    static func uptimeNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    @inline(__always)
    private func add(_ amount: UInt64, at index: Int) { words[index].value.add(amount, ordering: .relaxed) }

    /// Counts one item that ran at `priority`: four relaxed atomic adds (each histogram's bucket and sum).
    // perf-hot: 50ns (every lane item)
    func record(_ priority: WorkPriority, waitNanos: UInt64, runNanos: UInt64) {
        let wait = priority.rawValue * Self.priorityWords
        let run = wait + Self.histogramWords
        add(1, at: wait + LaneHistogram.bucket(forNanos: waitNanos))
        add(waitNanos, at: wait + LaneHistogram.bucketCount)
        add(1, at: run + LaneHistogram.bucket(forNanos: runNanos))
        add(runNanos, at: run + LaneHistogram.bucketCount)
    }

    /// The histograms of every priority now, highest priority first (allocates; read off the hot path).
    func snapshot(lane: BlockingLane) -> [LaneTimes] {
        WorkPriority.allCases.reversed().map { priority in
            let wait = priority.rawValue * Self.priorityWords
            return LaneTimes(lane: lane, priority: priority, wait: histogram(at: wait),
                             run: histogram(at: wait + Self.histogramWords))
        }
    }

    /// Zeroes every count and sum (`debug.work` `{"reset": true}`).
    func reset() {
        for word in words { word.value.store(0, ordering: .relaxed) }
    }

    private func histogram(at base: Int) -> LaneHistogram {
        LaneHistogram(counts: (0..<LaneHistogram.bucketCount).map { words[base + $0].value.load(ordering: .relaxed) },
                      sumNanos: words[base + LaneHistogram.bucketCount].value.load(ordering: .relaxed))
    }
}

/// One lane and priority's queue wait and run time (``BackgroundWork/laneTimes()``).
public struct LaneTimes: Sendable, Equatable {
    public var lane: BlockingLane
    public var priority: WorkPriority
    /// Submit to start: how long items waited for a slot, including the hop to the slot's thread.
    public var wait: LaneHistogram
    /// Start to end of each item's body on its slot thread.
    public var run: LaneHistogram

    public init(lane: BlockingLane, priority: WorkPriority, wait: LaneHistogram, run: LaneHistogram) {
        self.lane = lane
        self.priority = priority
        self.wait = wait
        self.run = run
    }
}

/// A read of one lane duration histogram: log2 buckets of the duration in units of 1/1024 ms (976.5625 ns), so
/// 1, 2, 4 ... ms are edges. Bucket 0 counts samples under one unit; bucket `i` counts samples in
/// `2^(i-1) ..< 2^i` units; the last bucket also counts everything longer (from about 67 s).
public struct LaneHistogram: Sendable, Equatable {
    /// Buckets, the overflow one included.
    public static let bucketCount = 28

    /// The count per bucket (``bucketCount`` entries).
    public var counts: [UInt64]
    /// The sum of every sample counted, in nanoseconds.
    public var sumNanos: UInt64

    public init(counts: [UInt64], sumNanos: UInt64) {
        self.counts = counts
        self.sumNanos = sumNanos
    }

    /// The bucket `nanos` counts in: the bit length of its whole 1/1024 ms units, at most the last bucket.
    @inline(__always)
    public static func bucket(forNanos nanos: UInt64) -> Int {
        // 1/1024 ms is 15625/16 ns; a duration past 2^60 ns (36 years) saturates instead of overflowing.
        let units = nanos < 1 << 60 ? (nanos << 4) / 15_625 : UInt64.max
        return min(UInt64.bitWidth - units.leadingZeroBitCount, bucketCount - 1)
    }

    /// The lower edge of `bucket` in nanoseconds (0 for bucket 0).
    public static func lowerEdgeNanos(_ bucket: Int) -> UInt64 {
        bucket <= 0 ? 0 : (UInt64(1) << UInt64(bucket - 1)) * 15_625 / 16
    }

    /// The upper edge of `bucket` in nanoseconds: every sample it counts is shorter, except in the last bucket.
    public static func upperEdgeNanos(_ bucket: Int) -> UInt64 {
        (UInt64(1) << UInt64(max(0, bucket))) * 15_625 / 16
    }

    public var count: UInt64 { counts.reduce(0) { $0 &+ $1 } }

    /// The upper edge of the highest bucket with a sample, so the longest sample is below it and at least half
    /// of it (no exact maximum is kept: that would cost a compare-exchange loop per item). 0 when empty.
    public var maxNanos: UInt64 {
        guard let top = counts.lastIndex(where: { $0 > 0 }) else { return 0 }
        return Self.upperEdgeNanos(top)
    }

    /// The `quantile` (0...1) in nanoseconds, interpolated by rank inside the bucket the rank falls in
    /// (Chromium's percentile from a bucketed histogram); the estimate and the true value share that bucket.
    /// 0 when empty.
    public func percentileNanos(_ quantile: Double) -> UInt64 {
        let total = count
        guard total > 0 else { return 0 }
        let rank = max(1, UInt64(exactly: (Double(total) * min(max(quantile, 0), 1)).rounded(.up)) ?? total)
        var seen: UInt64 = 0
        for (bucket, bucketCount) in counts.enumerated() where bucketCount > 0 {
            guard seen + bucketCount >= rank else {
                seen += bucketCount
                continue
            }
            let low = Self.lowerEdgeNanos(bucket), high = Self.upperEdgeNanos(bucket)
            let fraction = Double(rank - seen) / Double(bucketCount)
            return low + (UInt64(exactly: (Double(high - low) * fraction).rounded()) ?? 0)
        }
        return maxNanos
    }

    /// Adds `other`'s counts and sum to this one's (the same lane and priority across reads, or all lanes).
    public func merged(with other: LaneHistogram) -> LaneHistogram {
        LaneHistogram(counts: zip(counts, other.counts).map { $0 &+ $1 }, sumNanos: sumNanos &+ other.sumNanos)
    }
}
