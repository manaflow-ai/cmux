#if DEBUG || CMUX_BENCH_HOOKS
/// The append-only record of reported violations (plans/cmux-next/invariants-DESIGN.md section 2.2): a ring of
/// the last ``capacity`` with a sequence number that only grows, so a harness that reads `since` its cursor after
/// every step sees every violation, and knows when the ring dropped some before it read them.
@MainActor
public final class InvariantLedger {
    /// Violations kept; older ones drop out (a reader past them sees `dropped`).
    public static let capacity = 1024

    private var entries: [InvariantViolation] = []
    /// The newest sequence number (0 before the first violation).
    public private(set) var lastSeq: UInt64 = 0

    public init() {}

    /// The oldest sequence number still kept (``lastSeq`` + 1 when nothing is kept).
    public var oldestSeq: UInt64 { entries.first?.seq ?? lastSeq + 1 }

    /// Every violation still kept, oldest first.
    public var all: [InvariantViolation] { entries }

    /// Appends the violation `make` builds with the next sequence number, and returns it.
    func append(_ make: (UInt64) -> InvariantViolation) -> InvariantViolation {
        lastSeq += 1
        let violation = make(lastSeq)
        entries.append(violation)
        if entries.count > Self.capacity { entries = Array(entries.suffix(Self.capacity)) }
        return violation
    }

    /// The violations after `seq`, oldest first, and whether the ring dropped any of them before this read.
    public func since(_ seq: UInt64) -> (violations: [InvariantViolation], dropped: Bool) {
        (entries.filter { $0.seq > seq }, seq < oldestSeq - 1)
    }

    /// Adds what the app learned after the report: the journal's position and the report file.
    public func annotate(_ seq: UInt64, journalTail: UInt64?, report: String?) {
        guard let index = entries.lastIndex(where: { $0.seq == seq }) else { return }
        if let journalTail { entries[index].journalTail = journalTail }
        if let report { entries[index].report = report }
    }
}
#endif
