#if DEBUG || CMUX_BENCH_HOOKS
/// An action that ran in the turn a violation was found in (``InvariantTrigger/actions``): its id, its origin and
/// its run number in this registry. Noting one builds no string: both are the action's own raw values.
public struct InvariantActionCause: Hashable, Sendable, Codable {
    public let id: String
    public let origin: String
    /// The registry's count of noted actions when this one ran (1 first).
    public let index: UInt64

    public init(id: String, origin: String, index: UInt64) {
        self.id = id
        self.origin = origin
        self.index = index
    }
}

/// The last few actions, in a fixed ring: noting one (``InvariantRegistry/noteAction(_:origin:)``, on every action's
/// own turn, armed or not) writes one slot and allocates nothing; only a trigger that names them builds an array.
struct InvariantActionRing: Sendable {
    private var slots: [InvariantActionCause?]
    private var next = 0
    private(set) var count = 0

    init(capacity: Int) {
        slots = Array(repeating: nil, count: capacity)
    }

    var isEmpty: Bool { count == 0 }

    mutating func append(_ cause: InvariantActionCause) {
        slots[next] = cause
        next = (next + 1) % slots.count
        count = min(count + 1, slots.count)
    }

    /// Forgets every action; the slots stay.
    mutating func removeAll() {
        count = 0
    }

    /// The kept actions, oldest first.
    var ordered: [InvariantActionCause] {
        (0..<count).compactMap { slots[(next - count + $0 + slots.count) % slots.count] }
    }
}
#endif
