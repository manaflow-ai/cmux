#if DEBUG || CMUX_BENCH_HOOKS
/// One subject a liveness rule waits on (``InvariantRule/liveness(id:row:rows:statement:owner:reads:limit:cost:interim:pending:)``):
/// still pending at its rule's limit after `since`, it is a violation. The rule only reports; it never changes state.
public struct InvariantPending: Hashable, Sendable {
    public let subject: InvariantSubject
    /// When the wait began; nil: when the registry first saw this subject pending.
    public let since: ContinuousClock.Instant?
    /// What waits, for the report ("focus on tab_7 (content)").
    public let detail: String

    public init(subject: InvariantSubject, since: ContinuousClock.Instant? = nil, detail: String) {
        self.subject = subject
        self.since = since
        self.detail = detail
    }
}
#endif
