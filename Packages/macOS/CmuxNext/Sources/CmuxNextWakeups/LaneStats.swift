import CmuxNextCompat
import Darwin

/// How long one ``BackgroundWork`` lane's items waited for a slot (submit to start) and ran (start to end), per
/// ``WorkPriority``, in every build (Release too): the lane side of Chrome's thread pool latency metrics,
/// `ThreadPool.TaskLatencyMicroseconds.<group>.<priority>` (base/task/thread_pool/task_tracker.cc
/// `TaskTracker::RecordLatencyHistogram`, which counts post to start per priority), plus the run time.
///
/// The buckets are log2 of the duration in 1/1024 ms (``LaneHistogram``), so a millisecond and its doubles are
/// bucket edges. The counters are relaxed atomics in one fixed allocation, addressed through
/// ``AtomicPointerSlot`` (Chromium's flat `SampleVector` counts): ``record(_:waitNanos:runNanos:)`` takes no lock,
/// allocates nothing and reads no clock (the lane passes the stamps it took). Each priority's block starts on its
/// own cache line, so the per-priority slot threads of a lane do not share one.
///
/// ``snapshot(lane:resetting:)`` with `resetting` takes each word with one atomic exchange, so every add lands in
/// exactly one read: none is lost between a report and its reset (as `ObservationLedger`'s read-and-reset). A
/// record running during that read may put its count in one read and its sum in the next.
final class LaneStats: Sendable {
    /// Words per histogram: one per bucket, then the sum of the samples in nanoseconds.
    private static let histogramWords = LaneHistogram.bucketCount + 1
    /// Words per priority: the wait histogram, then the run histogram, padded to a whole number of cache lines.
    private static let priorityWords = (2 * histogramWords + lineWords - 1) / lineWords * lineWords
    private static let wordCount = WorkPriority.allCases.count * priorityWords
    /// The cache line (128 bytes on Apple silicon) in words; the allocation is aligned to it.
    private static let lineWords = 16
    private static let lineBytes = lineWords * MemoryLayout<UInt64>.stride

    /// The address of `wordCount` zeroed words, by priority, then wait and run, then bucket and sum: allocated in
    /// `init`, freed in `deinit`, never resized. Kept as an integer so the class is `Sendable` with no unchecked
    /// claim (as ``CrashKeySlots``); every access goes through ``AtomicPointerSlot``.
    private let wordsAddress: UInt

    init() {
        let words = UnsafeMutableRawPointer.allocate(byteCount: Self.wordCount * MemoryLayout<UInt64>.stride,
                                                     alignment: Self.lineBytes)
        _ = words.initializeMemory(as: UInt64.self, repeating: 0, count: Self.wordCount)
        wordsAddress = UInt(bitPattern: words)
    }

    deinit {
        UnsafeMutableRawPointer(bitPattern: wordsAddress)?.deallocate()
    }

    /// The clock the lanes stamp items with by default: `CLOCK_UPTIME_RAW` nanoseconds (`mach_absolute_time`
    /// in nanoseconds), one commpage read with no system call.
    static func uptimeNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    @inline(__always)
    private func slot(_ index: Int) -> AtomicPointerSlot {
        // The block is `wordCount` words from `init`; `index` is a priority's word below `wordCount`.
        AtomicPointerSlot(UnsafeMutablePointer<UInt64>(bitPattern: wordsAddress).unsafelyUnwrapped + index)
    }

    /// Counts one item that ran at `priority`: four relaxed atomic adds (each histogram's bucket and sum).
    // perf-hot: 100ns lane-item
    func record(_ priority: WorkPriority, waitNanos: UInt64, runNanos: UInt64) {
        let wait = priority.rawValue * Self.priorityWords
        let run = wait + Self.histogramWords
        slot(wait + LaneHistogram.bucket(forNanos: waitNanos)).add(1, ordering: .relaxed)
        slot(wait + LaneHistogram.bucketCount).add(waitNanos, ordering: .relaxed)
        slot(run + LaneHistogram.bucket(forNanos: runNanos)).add(1, ordering: .relaxed)
        slot(run + LaneHistogram.bucketCount).add(runNanos, ordering: .relaxed)
    }

    /// The histograms of every priority now, highest priority first (allocates; read off the hot path). With
    /// `resetting`, each word is read and zeroed in one atomic exchange (`debug.work` `{"reset": true}`).
    func snapshot(lane: BlockingLane, resetting: Bool = false) -> [LaneTimes] {
        WorkPriority.allCases.reversed().map { priority in
            let wait = priority.rawValue * Self.priorityWords
            return LaneTimes(lane: lane, priority: priority, wait: histogram(at: wait, resetting: resetting),
                             run: histogram(at: wait + Self.histogramWords, resetting: resetting))
        }
    }

    private func histogram(at base: Int, resetting: Bool) -> LaneHistogram {
        let take = { (index: Int) -> UInt64 in
            resetting ? self.slot(index).exchange(0, ordering: .relaxed) : self.slot(index).load(ordering: .relaxed)
        }
        return LaneHistogram(counts: (0..<LaneHistogram.bucketCount).map { take(base + $0) },
                             sumNanos: take(base + LaneHistogram.bucketCount))
    }
}

/// One lane and priority's queue wait and run time (``BackgroundWork/laneTimes(resetting:)``).
public struct LaneTimes: Sendable, Equatable {
    /// The blocking lane the items ran on.
    public var lane: BlockingLane
    /// The priority they were submitted at.
    public var priority: WorkPriority
    /// Submit to start: how long items waited for a slot, including the hop to the slot's thread.
    public var wait: LaneHistogram
    /// Start to end of each item's body on its slot thread.
    public var run: LaneHistogram

    /// The times of `lane` at `priority`.
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

    /// A histogram of `counts` per bucket and their `sumNanos`.
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

    /// Every sample counted, over all buckets.
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
