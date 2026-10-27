import CmuxNextWakeups

extension IdleEnergyStats {
    typealias JSONValue = EnergyReport.JSONValue

    /// `debug.energy`'s `idle`: the main process's interrupt wakeups per second over this launch's
    /// idle minutes (`scope`; `processes` has the helpers), as the histogram (`le` is each bucket's
    /// upper bound) and its p50/p95/p99. The rates are null before the first idle minute.
    var json: JSONValue {
        func rate(_ value: Double?) -> JSONValue { value.map { JSONValue.number($0) } ?? .null }
        let buckets = counts.enumerated().map { index, count -> JSONValue in
            ["le": .string(Self.label(ofBucket: index)), "count": EnergyReport.integer(count)]
        }
        return [
            "scope": .string("mainProcess"),
            "idleAfterSeconds": EnergyReport.integer(Self.idleAfterNanos / 1_000_000_000),
            "windowSeconds": EnergyReport.integer(Self.windowNanos / 1_000_000_000),
            "samples": EnergyReport.integer(sampleCount),
            "windowsWithInput": EnergyReport.integer(windowsWithInput),
            "p50": rate(percentile(0.5)),
            "p95": rate(percentile(0.95)),
            "p99": rate(percentile(0.99)),
            "max": rate(sampleCount > 0 ? maxRate : nil),
            "last": rate(lastRate),
            "buckets": .array(buckets),
        ]
    }
}
