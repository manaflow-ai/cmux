#if DEBUG || CMUX_BENCH_HOOKS
/// One checkpoint the oracle recorder took: at the end of a perform turn (`turn`, the optimistic
/// state the person sees) or on request (`mark`, the runner's `settled` checkpoint after
/// `debug.oracle.settle`). Invariant I3 compares a turn's projection with the settled mark's
/// (plans/cmux-next/chrome-parity/p15-oracle.md section 3D). A projection is the snapshot after
/// scripts/cmux-next/oracle/normalize.py, which drops the commit counters, rewrites times and relabels
/// ids by the schema, so the checkpoint keeps the facet values and the runner normalizes turn and
/// settled alike. The values are what `debug.oracle.snapshot` answers: private text is already hashed.
public struct OracleCheckpoint: Sendable, Hashable {
    public enum Kind: String, Sendable {
        case turn
        case mark
    }

    /// 1 for the first checkpoint since the recorder was made, never reused (a cleared ring goes on counting).
    public let sequence: UInt64
    public let kind: Kind
    /// The action id of a turn, the label of a mark.
    public let label: String
    /// Who started the turn's run; nil for a mark.
    public let origin: String?
    /// Whether the turn's perform ran (false: refused); nil for a mark.
    public let ran: Bool?
    /// The armed facets as `{<facet>: <value>}`, the `debug.oracle.snapshot` result shape; nil when
    /// ``failure`` is set.
    public let facets: OracleValue?
    /// Why the facets could not be read (a provider failed); nil when ``facets`` is set.
    public let failure: String?

    public init(sequence: UInt64, kind: Kind, label: String, origin: String?, ran: Bool?,
                facets: OracleValue?, failure: String?) {
        self.sequence = sequence
        self.kind = kind
        self.label = label
        self.origin = origin
        self.ran = ran
        self.facets = facets
        self.failure = failure
    }

    /// The checkpoint as the `debug.oracle.turns` entry.
    public var value: OracleValue {
        var members: [String: OracleValue] = [
            "sequence": .number(Double(sequence)), "kind": .string(kind.rawValue), "label": .string(label),
        ]
        if let origin { members["origin"] = .string(origin) }
        if let ran { members["ran"] = .bool(ran) }
        if let facets { members["facets"] = facets }
        if let failure { members["failure"] = .string(failure) }
        return .object(members)
    }
}

/// The recorder's last ``capacity`` checkpoints, oldest first. Fixed slots: they are made once, a
/// full ring overwrites its oldest slot, and a reader learns what it missed from ``dropped`` and the
/// sequence numbers. Each slot holds its checkpoint's facet values, so an armed ring holds up to
/// ``capacity`` snapshots of the armed facets: the runner arms the facets its case compares and
/// clears the ring when it has read a case's checkpoints.
public struct OracleTurnRing: Sendable {
    public static let defaultCapacity = 256

    public let capacity: Int
    private var slots: [OracleCheckpoint?]
    /// Checkpoints in the ring now.
    public private(set) var count = 0
    /// The sequence the next checkpoint gets.
    public private(set) var nextSequence: UInt64 = 1
    /// Checkpoints overwritten before anyone cleared them, since the recorder was made.
    public private(set) var dropped: UInt64 = 0

    /// A ring of `capacity` checkpoints (at least one).
    public init(capacity: Int = OracleTurnRing.defaultCapacity) {
        let capacity = max(capacity, 1)
        self.capacity = capacity
        slots = Array(repeating: nil, count: capacity)
    }

    /// Records a checkpoint under the next sequence and returns it.
    @discardableResult
    public mutating func append(kind: OracleCheckpoint.Kind, label: String, origin: String? = nil, ran: Bool? = nil,
                                facets: OracleValue?, failure: String? = nil) -> OracleCheckpoint {
        let checkpoint = OracleCheckpoint(sequence: nextSequence, kind: kind, label: label, origin: origin, ran: ran,
                                          facets: facets, failure: failure)
        slots[Int((nextSequence - 1) % UInt64(capacity))] = checkpoint
        nextSequence += 1
        if count == capacity { dropped += 1 } else { count += 1 }
        return checkpoint
    }

    /// Empties the ring; sequences go on from where they were.
    public mutating func clear() {
        for index in slots.indices { slots[index] = nil }
        count = 0
    }

    /// The checkpoints in the ring with a sequence above `after` (all when nil), oldest first, at
    /// most the last `last` of them when given.
    public func checkpoints(after: UInt64? = nil, last: Int? = nil) -> [OracleCheckpoint] {
        var from = nextSequence - UInt64(count)
        if let after {
            guard after < nextSequence - 1 else { return [] }
            from = max(from, after + 1)
        }
        if let last, last >= 0, nextSequence - from > UInt64(last) { from = nextSequence - UInt64(last) }
        return (from..<nextSequence).compactMap { slots[Int(($0 - 1) % UInt64(capacity))] }
    }
}
#endif
