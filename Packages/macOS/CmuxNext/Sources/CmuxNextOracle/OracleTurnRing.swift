#if DEBUG || CMUX_BENCH_HOOKS
/// One checkpoint the oracle recorder took: at the end of a perform turn (`turn`, the optimistic
/// state the person sees) or on request (`mark`, the runner's `settled` checkpoint after
/// `debug.oracle.settle`). Invariant I3 compares a turn's hash with the settled mark's
/// (plans/cmux-next/chrome-parity/p15-oracle.md section 3D). Hashes only: a facet value never
/// leaves the app through the ring.
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
    /// The checkpoint's facets: the hash of the whole `{<facet>: <value>}` object, and of each facet.
    public let snapshot: OracleSnapshotHash?
    /// Why the facets could not be read (a provider failed); nil when ``snapshot`` is set.
    public let failure: String?

    public init(sequence: UInt64, kind: Kind, label: String, origin: String?, ran: Bool?,
                snapshot: OracleSnapshotHash?, failure: String?) {
        self.sequence = sequence
        self.kind = kind
        self.label = label
        self.origin = origin
        self.ran = ran
        self.snapshot = snapshot
        self.failure = failure
    }

    /// The checkpoint as the `debug.oracle.turns` entry.
    public var value: OracleValue {
        var members: [String: OracleValue] = [
            "sequence": .number(Double(sequence)), "kind": .string(kind.rawValue), "label": .string(label),
        ]
        if let origin { members["origin"] = .string(origin) }
        if let ran { members["ran"] = .bool(ran) }
        if let snapshot {
            members["hash"] = .string(OracleSnapshotHash.hex(snapshot.whole))
            members["facets"] = .object(snapshot.facets.mapValues { .string(OracleSnapshotHash.hex($0)) })
        }
        if let failure { members["failure"] = .string(failure) }
        return .object(members)
    }
}

/// The 64-bit FNV-1a hashes of a snapshot's canonical JSON (``OracleValue/canonicalJSON``): equal
/// snapshots have equal hashes in any process of any build, so a turn compares with a later mark.
/// FNV-1a and not a cryptographic hash: the values hashed are already free of private text (a
/// provider hashes that itself), and the hash only tells two states apart.
public struct OracleSnapshotHash: Sendable, Hashable {
    /// The hash of the whole `{<facet>: <value>}` object.
    public let whole: UInt64
    /// The hash of each facet's value, by facet name.
    public let facets: [String: UInt64]

    /// Hashes `snapshot`, an object of facet values.
    public init(_ snapshot: [String: OracleValue]) {
        whole = Self.fnv1a(OracleValue.object(snapshot).canonicalJSON)
        facets = snapshot.mapValues { Self.fnv1a($0.canonicalJSON) }
    }

    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// `fnv1a64:` and 16 lowercase hex digits.
    public static func hex(_ hash: UInt64) -> String {
        let digits = String(hash, radix: 16)
        return "fnv1a64:" + String(repeating: "0", count: 16 - digits.count) + digits
    }
}

/// The recorder's last ``capacity`` checkpoints, oldest first. Fixed storage: the slots are made
/// once, a full ring overwrites its oldest slot, and a reader learns what it missed from
/// ``dropped`` and the sequence numbers.
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
                                snapshot: OracleSnapshotHash?, failure: String? = nil) -> OracleCheckpoint {
        let checkpoint = OracleCheckpoint(sequence: nextSequence, kind: kind, label: label, origin: origin, ran: ran,
                                          snapshot: snapshot, failure: failure)
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
