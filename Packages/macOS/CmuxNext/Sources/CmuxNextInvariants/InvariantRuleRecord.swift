#if DEBUG || CMUX_BENCH_HOOKS
/// What the registry keeps for one declared rule between its runs.
struct InvariantRuleRecord: Sendable {
    /// Subjects whose signature (`<id>@<host>@<subject>`) was reported and not yet found clear by a run that checked
    /// that subject.
    var reported: Set<InvariantSubject> = []
    /// A liveness rule's subjects pending since (for those its `pending` gives no time).
    var firstSeen: [InvariantSubject: ContinuousClock.Instant] = [:]
    /// A liveness rule's earliest limit still ahead.
    var nextDue: ContinuousClock.Instant?
    var checks: UInt64 = 0
    var violations: UInt64 = 0
    var timing = InvariantTiming(limitMicros: InvariantRegistry.costLimitMicros)
}
#endif
