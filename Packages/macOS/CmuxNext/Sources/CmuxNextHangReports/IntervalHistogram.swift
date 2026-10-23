/// One allowlisted Release signpost interval as MetricKit aggregated it (`MXSignpostMetric`):
/// how often it ran and how long it took, never a single event.
public nonisolated struct IntervalHistogram: Codable, Sendable, Equatable {
    /// One of ``HangReportSignposts/categories``.
    public var category: String
    /// A static identifier (`[a-z0-9_.-]{1,48}`).
    public var name: String
    public var count: Int
    public var buckets: [HistogramBucket]
    /// Milliseconds of hitch per second inside the interval; nil when MetricKit gave none.
    public var hitchMsPerS: Double?

    public init(category: String, name: String, count: Int, buckets: [HistogramBucket], hitchMsPerS: Double?) {
        self.category = category
        self.name = name
        self.count = max(0, count)
        self.buckets = HistogramBucket.normalized(buckets)
        self.hitchMsPerS = hitchMsPerS
    }
}
