/// Summary of millisecond samples (nearest-rank percentiles).
public struct Distribution: Codable, Sendable, Hashable {
    public var count: Int
    public var min: Double
    public var p50: Double
    public var p95: Double
    public var p99: Double
    public var max: Double
    public var mean: Double

    public init(milliseconds samples: [Double]) {
        let sorted = samples.sorted()
        count = sorted.count
        guard !sorted.isEmpty else {
            min = 0; p50 = 0; p95 = 0; p99 = 0; max = 0; mean = 0
            return
        }
        func rank(_ quantile: Double) -> Double {
            let index = Int((quantile * Double(sorted.count)).rounded(.up)) - 1
            return sorted[Swift.min(Swift.max(index, 0), sorted.count - 1)]
        }
        min = sorted[0]
        p50 = rank(0.50)
        p95 = rank(0.95)
        p99 = rank(0.99)
        max = sorted[sorted.count - 1]
        mean = sorted.reduce(0, +) / Double(sorted.count)
    }
}

extension Duration {
    /// Milliseconds as a double.
    var milliseconds: Double {
        let parts = components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
}
