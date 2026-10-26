import CmuxNextWakeups

extension IdleEnergyStats {
    typealias JSONValue = EnergyReport.JSONValue

    /// `debug.energy`'s `idle`: the app's interrupt wakeups per second over this launch's idle
    /// minutes, as the histogram (`le` is each bucket's upper bound) and its p50/p95/p99. The rates
    /// are null before the first idle minute.
    var json: JSONValue {
        func rate(_ value: Double?) -> JSONValue { value.map { JSONValue.number($0) } ?? .null }
        let buckets = counts.enumerated().map { index, count -> JSONValue in
            ["le": .string(Self.label(ofBucket: index)), "count": JSONValue(Int(truncatingIfNeeded: count))]
        }
        return [
            "window_s": JSONValue(Int(truncatingIfNeeded: Self.windowNanos / 1_000_000_000)),
            "samples": JSONValue(Int(truncatingIfNeeded: sampleCount)),
            "windows_with_input": JSONValue(Int(truncatingIfNeeded: windowsWithInput)),
            "p50": rate(percentile(0.5)),
            "p95": rate(percentile(0.95)),
            "p99": rate(percentile(0.99)),
            "max": rate(sampleCount > 0 ? maxRate : nil),
            "last": rate(lastRate),
            "buckets": .array(buckets),
        ]
    }
}
