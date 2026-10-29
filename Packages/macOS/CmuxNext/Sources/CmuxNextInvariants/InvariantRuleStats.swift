#if DEBUG || CMUX_BENCH_HOOKS
/// One rule's counts and run times as `debug.invariants {rules: true}` lists them.
public struct InvariantRuleStats: Hashable, Sendable {
    public let checks: UInt64
    public let violations: UInt64
    /// Run time percentiles and maximum, in microseconds (shared memo builds not included).
    public let p50: Double
    public let p95: Double
    public let p99: Double
    public let max: Double

    init(_ record: InvariantRuleRecord) {
        checks = record.checks
        violations = record.violations
        p50 = record.timing.percentile(0.5)
        p95 = record.timing.percentile(0.95)
        p99 = record.timing.percentile(0.99)
        max = record.timing.maxMicros
    }

    init(timing: InvariantTiming) {
        checks = timing.count
        violations = 0
        p50 = timing.percentile(0.5)
        p95 = timing.percentile(0.95)
        p99 = timing.percentile(0.99)
        max = timing.maxMicros
    }
}
#endif
