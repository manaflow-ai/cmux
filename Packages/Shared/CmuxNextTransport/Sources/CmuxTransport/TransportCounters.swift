/// Observability is contractual (8.1, 8.2): admissions, denials by reason,
/// closes by reason, renewals. The lab screen renders these live in P1.
public struct TransportCounters: Sendable, Equatable {
    /// Number of successful initial admissions.
    public var admissions = 0
    /// Admission denials grouped by stable denial code.
    public var denialsByCode: [String: Int] = [:]
    /// Session closes grouped by stable close code.
    public var closesByCode: [String: Int] = [:]
    /// Number of accepted in-session grant renewals.
    public var grantRenewals = 0
    /// Number of refused in-session grant renewals.
    public var grantRenewalRejections = 0

    /// Creates zeroed counters for a new host lifecycle.
    public init() {}
}
