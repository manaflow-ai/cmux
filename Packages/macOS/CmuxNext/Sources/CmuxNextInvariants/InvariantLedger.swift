#if DEBUG || CMUX_BENCH_HOOKS
public import Foundation

/// The append-only record of reported violations (plans/cmux-next/invariants-DESIGN.md section 2.2): a ring of
/// the last ``capacity`` with a sequence number that only grows, so a harness that reads `since` its cursor after
/// every step sees every violation, and knows when the ring dropped some before it read them. Sequence numbers are
/// consecutive, so an append overwrites one slot and a read finds its first entry by arithmetic: nothing is copied
/// when the ring is full.
@MainActor
public final class InvariantLedger {
    /// Violations kept; older ones drop out (a reader past them sees `dropped`).
    public static let capacity = 1024

    /// The slots; the violation with sequence number `seq` is at `(seq - 1) % capacity` while it is kept.
    private var slots: [InvariantViolation] = []
    /// The newest sequence number (0 before the first violation).
    public private(set) var lastSeq: UInt64 = 0

    public init() {
        slots.reserveCapacity(Self.capacity)
    }

    /// How many violations are kept.
    private var count: UInt64 { min(lastSeq, UInt64(Self.capacity)) }

    /// The oldest sequence number still kept (``lastSeq`` + 1 when nothing is kept).
    public var oldestSeq: UInt64 { lastSeq - count + 1 }

    /// Every violation still kept, oldest first.
    public var all: [InvariantViolation] { since(0).violations }

    /// Appends the violation `make` builds with the next sequence number, and returns it.
    func append(_ make: (UInt64) -> InvariantViolation) -> InvariantViolation {
        lastSeq += 1
        let violation = make(lastSeq)
        if slots.count < Self.capacity {
            slots.append(violation)
        } else {
            slots[slot(of: lastSeq)] = violation
        }
        return violation
    }

    /// The violations after `seq`, oldest first, and whether the ring dropped any of them before this read.
    public func since(_ seq: UInt64) -> (violations: [InvariantViolation], dropped: Bool) {
        let first = max(seq + 1, oldestSeq)
        guard first <= lastSeq else { return ([], seq + 1 < oldestSeq) }
        return ((first...lastSeq).map { slots[slot(of: $0)] }, seq + 1 < oldestSeq)
    }

    /// Adds what the app learned after the report: the journal's position, the report file once it is written, and
    /// the rule's read state (at most ``InvariantViolation/stateLimit`` bytes) once it is encoded.
    public func annotate(_ seq: UInt64, journalTail: UInt64? = nil, report: String? = nil, state: Data? = nil) {
        guard seq >= oldestSeq, seq <= lastSeq else { return }
        let index = slot(of: seq)
        if let journalTail { slots[index].journalTail = journalTail }
        if let report { slots[index].report = report }
        if let state, state.count <= InvariantViolation.stateLimit { slots[index].state = state }
    }

    private func slot(of seq: UInt64) -> Int {
        Int((seq - 1) % UInt64(Self.capacity))
    }
}
#endif
