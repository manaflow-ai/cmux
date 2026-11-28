import Foundation

/// Fixed-memory distribution. The final bucket includes overflow above 60s.
struct MobileFeedTimingHistogram {
    static let boundsMilliseconds = [8, 12, 17, 25, 34, 50, 100, 250, 1_000, 60_000]
    private(set) var buckets = Array(repeating: 0, count: boundsMilliseconds.count)
    private(set) var count = 0
    private(set) var maximumMilliseconds = 0
    private(set) var totalMicroseconds = 0

    mutating func record(seconds: Double) {
        guard seconds.isFinite, seconds >= 0, count < 1_000_000 else { return }
        let ms = min(60_000, seconds * 1_000)
        let index = Self.boundsMilliseconds.firstIndex { ms <= Double($0) } ?? buckets.count - 1
        buckets[index] += 1
        count += 1
        maximumMilliseconds = max(maximumMilliseconds, Int(ms.rounded(.up)))
        totalMicroseconds += Int((ms * 1_000).rounded())
    }

    var encoded: String { "[" + buckets.map(String.init).joined(separator: ",") + "]" }
}
