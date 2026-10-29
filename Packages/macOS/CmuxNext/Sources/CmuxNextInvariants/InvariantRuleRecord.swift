#if DEBUG || CMUX_BENCH_HOOKS
/// What the registry keeps for one declared rule between its runs.
struct InvariantRuleRecord: Sendable {
    /// Signatures reported and not yet found clear.
    var reported: Set<String> = []
    /// Signatures found once and waiting for the next run (a rule that confirms at its next check).
    var suspected: Set<String> = []
    /// A liveness rule's subjects pending since (for those its `pending` gives no time).
    var firstSeen: [InvariantSubject: ContinuousClock.Instant] = [:]
    /// A liveness rule's earliest limit still ahead.
    var nextDue: ContinuousClock.Instant?
    var checks: UInt64 = 0
    var violations: UInt64 = 0
    var timing = InvariantTiming()
}
#endif
