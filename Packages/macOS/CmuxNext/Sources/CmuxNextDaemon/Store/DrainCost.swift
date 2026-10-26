/// What the store's drains of the event inbox cost (owner `DaemonStore.drain`): one sample per
/// batch in a duration histogram, the events it applied, and the counts of the whole-list passes a
/// batch can start. A batch costs what changed: a storm of title, scroll or status events in hidden
/// workspaces flattens no sidebar and walks no workspace list, and the counters prove it.
///
/// The buckets are the field histograms' log-linear layout (`HistogramID.Layout.logLinear`, four per
/// power of two, Chromium's exponential `UMA_HISTOGRAM_CUSTOM_MICROSECONDS_TIMES` in
/// base/metrics/histogram_macros.h at a finer step): bucket 0 holds drains under 1 us, the last one
/// drains of ``maximumMicros`` or more.
///
/// ```swift
/// let p99 = store.drainCost.percentileMicros(0.99)   // script-storm-bench --hidden: <= 1_000
/// ```
public struct DrainCost: Sendable, Equatable {
    /// The owner the histogram is filed under.
    public static let owner = "DaemonStore.drain"
    /// Drains of 2^20 us (about 1 s) or more count in the overflow bucket.
    public static let maximumMicros: Int64 = 1 << 20
    static let powers = 20
    /// The underflow bucket, four per power of two, and the overflow bucket.
    public static let bucketCount = 1 + 4 * powers + 1

    /// Drains counted, by bucket (``bucket(micros:)``).
    public private(set) var buckets = [Int](repeating: 0, count: DrainCost.bucketCount)
    /// Drains that applied a batch.
    public private(set) var batches = 0
    /// Events those batches held (after the inbox coalesced them).
    public private(set) var events = 0
    /// The longest drain, in us.
    public private(set) var maxMicros: Int64 = 0
    /// Sidebar flattenings (`DaemonStore.recomputeSidebar`) by any apply: a batch that only
    /// changes records inside workspaces runs none.
    public internal(set) var sidebarFlattens = 0
    /// `onWorkspaceListChanged` calls: only a workspace joining or leaving the list makes one.
    public internal(set) var listChanges = 0

    public init() {}

    /// The bucket a drain of `micros` counts in.
    public static func bucket(micros: Int64) -> Int {
        guard micros >= 1 else { return 0 }
        guard micros < maximumMicros else { return bucketCount - 1 }
        let power = 63 - micros.leadingZeroBitCount
        let base = Int64(1) << power
        let quarter = Int(truncatingIfNeeded: (micros - base) * 4 / base)
        return 1 + 4 * power + quarter
    }

    /// The exclusive upper edge of `bucket`, in us: the smallest value the next bucket counts
    /// (``maximumMicros`` for the overflow bucket).
    public static func upperEdgeMicros(_ bucket: Int) -> Int64 {
        guard bucket > 0 else { return 1 }
        guard bucket < bucketCount - 1 else { return maximumMicros }
        let power = (bucket - 1) / 4
        let quarters = Int64(truncatingIfNeeded: (bucket - 1) % 4 + 1)
        let base = Int64(1) << power
        return base + (quarters * base + 3) / 4
    }

    /// Counts one drain of `duration` that applied `events` events.
    mutating func record(_ duration: Duration, events count: Int) {
        let (seconds, attoseconds) = duration.components
        let micros = max(seconds &* 1_000_000 &+ attoseconds / 1_000_000_000_000, 0)
        buckets.modify(checked: Self.bucket(micros: micros)) { $0 += 1 }
        batches &+= 1
        events &+= count
        maxMicros = max(maxMicros, micros)
    }

    /// The upper edge (us) of the bucket that holds the `quantile` drain (0.99: p99); 0 with no drain.
    public func percentileMicros(_ quantile: Double) -> Int64 {
        guard batches > 0 else { return 0 }
        let rank = max(Int(exactly: (quantile * Double(batches)).rounded(.up)) ?? batches, 1)
        var seen = 0
        for (bucket, count) in buckets.enumerated() {
            seen += count
            if seen >= rank { return min(Self.upperEdgeMicros(bucket), max(maxMicros, 1)) }
        }
        return maxMicros
    }

    /// The time `body` takes on `clock` (the store's injected ``DaemonStore/drainClock``).
    static func measured<C: Clock, T>(on clock: C, _ body: () -> T) -> (T, Duration) where C.Duration == Duration {
        let start = clock.now
        let result = body()
        return (result, start.duration(to: clock.now))
    }
}
