/// One launch milestone's durations for one ``LaunchTemperature``: how many launches and their
/// histogram over ``LaunchAggregate/bucketEdgesMs``, never one launch's exact time.
public nonisolated struct LaunchHistogram: Codable, Sendable, Equatable {
    /// The largest count a histogram or a bucket carries (the server's bound).
    public static let maxCount = 1_000_000_000

    /// The launches' temperature.
    public var temperature: LaunchTemperature
    /// How many launches fell in it.
    public var count: Int
    /// The duration histogram, measured from process start.
    public var buckets: [HistogramBucket]

    private enum CodingKeys: String, CodingKey {
        case temperature, count, buckets
    }

    /// Makes the value from its parts, with every count clamped to `0...maxCount`.
    public init(temperature: LaunchTemperature, count: Int, buckets: [HistogramBucket]) {
        self.temperature = temperature
        self.count = min(max(0, count), Self.maxCount)
        // Clamped before the merge (so its sum cannot overflow) and after it.
        self.buckets = HistogramBucket.normalized(buckets.map(Self.clamped)).map(Self.clamped)
    }

    private static func clamped(_ bucket: HistogramBucket) -> HistogramBucket {
        HistogramBucket(lowMs: bucket.lowMs, highMs: bucket.highMs, count: min(bucket.count, maxCount))
    }

    /// Decodes through ``init(temperature:count:buckets:)``, so a saved file is clamped too.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(temperature: try container.decode(LaunchTemperature.self, forKey: .temperature),
                  count: try container.decode(Int.self, forKey: .count),
                  buckets: try container.decode([HistogramBucket].self, forKey: .buckets))
    }

    /// `histograms` merged by temperature: at most one per temperature, in ``LaunchTemperature``
    /// order, empty ones left out.
    public static func merged(_ histograms: [LaunchHistogram]) -> [LaunchHistogram] {
        LaunchTemperature.allCases.compactMap { temperature in
            let same = histograms.filter { $0.temperature == temperature }
            let total = same.reduce(0) { min($0 + $1.count, maxCount) }
            let merged = LaunchHistogram(temperature: temperature, count: total, buckets: same.flatMap(\.buckets))
            return merged.count > 0 ? merged : nil
        }
    }
}
