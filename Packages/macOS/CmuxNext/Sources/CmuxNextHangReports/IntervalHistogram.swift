/// One allowlisted Release signpost interval as MetricKit aggregated it (`MXSignpostMetric`):
/// how often it ran and how long it took, never a single event; or (schema 3 only) one of the
/// watchdog's main-thread histograms in category ``HangReport/mainThreadCategory`` (`main.turn`,
/// `main.input_queueing`; ``HangReportBuilder/addMainThread(_:to:)``). The `launch` category carries
/// MetricKit's view of launch intervals; cmux's own launch milestones by temperature are in
/// ``HangReport/launches`` (``LaunchHistogram``), which MetricKit cannot split by temperature.
public nonisolated struct IntervalHistogram: Codable, Sendable, Equatable {
    /// One of ``HangReportSignposts/categories``, or ``HangReport/mainThreadCategory`` (schema 3).
    public var category: String
    /// A static identifier (`[a-z0-9_.-]{1,48}`).
    public var name: String
    /// How many values fell in it.
    public var count: Int
    /// The duration histogram.
    public var buckets: [HistogramBucket]
    /// Milliseconds of hitch per second inside the interval; nil when MetricKit gave none and
    /// always nil for a main-thread histogram.
    public var hitchMsPerS: Double?

    /// Makes the value from its parts.
    public init(category: String, name: String, count: Int, buckets: [HistogramBucket], hitchMsPerS: Double?) {
        self.category = category
        self.name = name
        self.count = max(0, count)
        self.buckets = HistogramBucket.normalized(buckets)
        self.hitchMsPerS = hitchMsPerS
    }
}
