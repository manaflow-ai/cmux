/// Frame timing for the benchmark screen: intervals between presented
/// frames while a workload runs, and the bytes parsed. Pure; the screen
/// feeds it from its draw callback and signposts each frame.
public struct FrameTimingStats: Hashable, Sendable {
    /// Seconds between consecutive frames.
    public private(set) var intervals: [Double] = []
    public private(set) var frames = 0
    public private(set) var bytes = 0
    private var lastFrame: Double?
    private var firstFrame: Double?

    public init() {}

    /// A frame was presented at `time` (seconds, monotonic).
    public mutating func frame(at time: Double) {
        frames += 1
        if let lastFrame, time >= lastFrame { intervals.append(time - lastFrame) }
        if firstFrame == nil { firstFrame = time }
        lastFrame = time
    }

    public mutating func parsed(_ count: Int) { bytes += max(count, 0) }

    /// Wall time from the first to the last frame.
    public var duration: Double {
        guard let firstFrame, let lastFrame else { return 0 }
        return lastFrame - firstFrame
    }

    /// The interval at quantile `q` (0...1, nearest rank), 0 with no intervals.
    public func percentile(_ q: Double) -> Double {
        guard !intervals.isEmpty else { return 0 }
        let sorted = intervals.sorted()
        let rank = Int((min(max(q, 0), 1) * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    /// Frames that took longer than 1.5 budgets (one or more missed vsyncs).
    public func hitches(budget: Double) -> Int {
        intervals.filter { $0 > budget * 1.5 }.count
    }

    public var bytesPerSecond: Double { duration > 0 ? Double(bytes) / duration : 0 }

    /// A flat report for `terminal-bench.json` and the screen's summary.
    public func report(workload: String, budget: Double) -> [String: String] {
        func ms(_ seconds: Double) -> String { String(format: "%.2f", seconds * 1000) }
        return [
            "workload": workload, "frames": String(frames), "bytes": String(bytes),
            "duration_ms": ms(duration), "p50_ms": ms(percentile(0.5)), "p95_ms": ms(percentile(0.95)),
            "p99_ms": ms(percentile(0.99)), "max_ms": ms(intervals.max() ?? 0),
            "budget_ms": ms(budget), "hitches": String(hitches(budget: budget)),
            "mib_per_s": String(format: "%.2f", bytesPerSecond / 1_048_576),
        ]
    }
}
