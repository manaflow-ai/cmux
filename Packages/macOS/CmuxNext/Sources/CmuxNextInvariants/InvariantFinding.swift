#if DEBUG || CMUX_BENCH_HOOKS
/// One broken instance of a rule, as its pure `check` returns it: the subject it is about and what is wrong.
public struct InvariantFinding: Hashable, Sendable, Codable {
    public let subject: InvariantSubject
    public let detail: String

    public init(subject: InvariantSubject, detail: String) {
        self.subject = subject
        self.detail = detail
    }
}
#endif
