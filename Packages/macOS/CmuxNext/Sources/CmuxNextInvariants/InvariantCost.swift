#if DEBUG || CMUX_BENCH_HOOKS
/// What one run of a rule costs (plans/cmux-next/invariants-DESIGN.md section 6). A per-turn rule only reads memory
/// (`cheap`, `walk`); a rule that asks another process (`ipc`) or counts every object (`census`) runs only from the
/// harness, and ``InvariantRegistry/declare(_:)`` refuses it at a per-turn check point.
public enum InvariantCost: String, Hashable, Sendable {
    /// A few reads of state the pass already holds.
    case cheap
    /// A walk of the dirty subjects (or of one memoized observation).
    case walk
    /// A request to another process (the daemon, a Chromium host).
    case ipc
    /// A count of every object of a kind.
    case census

    /// Whether a rule of this cost may run inside a turn.
    public var mayRunPerTurn: Bool { self == .cheap || self == .walk }
}
#endif
