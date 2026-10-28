/// One Chromium histogram's samples since the previous snapshot (the fork's `cmux_cef_histogram_snapshot`):
/// its non-empty buckets ascending, each `count` samples in `[minimum, maximum)`.
public nonisolated struct CEFHistogramDelta: Sendable, Equatable {
    /// One Chromium bucket.
    public nonisolated struct Bucket: Sendable, Equatable {
        public var minimum: Int64
        public var maximum: Int64
        public var count: Int64

        public init(minimum: Int64, maximum: Int64, count: Int64) {
            self.minimum = minimum
            self.maximum = maximum
            self.count = count
        }
    }

    /// Chromium's UMA name (`EventLatency.KeyPressed.TotalLatency`).
    public var name: String
    public var sum: Int64
    public var count: Int64
    public var buckets: [Bucket]

    public init(name: String, sum: Int64, count: Int64, buckets: [Bucket]) {
        self.name = name
        self.sum = sum
        self.count = count
        self.buckets = buckets
    }
}

/// Why a snapshot of Chromium's histograms gave nothing.
public nonisolated enum CEFHistogramHarvestError: Error, Hashable, Sendable {
    /// Chromium is not running in this process (not started yet, starting, stopping or failed).
    case notStarted
    /// The shim or the fork has no snapshot call (an older fork), or Chromium runs in the Chromium Host.
    case unsupported
    /// A name outside ``CEFHistogramHarvest/allowlist``, or the fork refused the request.
    case refused
    /// The snapshot's end call never came.
    case abandoned
}
