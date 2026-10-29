#if DEBUG || CMUX_BENCH_HOOKS
/// Where a rule runs (plans/cmux-next/invariants-DESIGN.md section 3): on the commit of a turn in which an action
/// ran, on the commit of a turn that touched a key the rule reads, or only when a harness asks
/// (`debug.invariants {check: true, ipc: true}`).
public struct InvariantCheckPoints: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// The commit of each turn in which an action ran (`ActionRegistry.willRunObservers`).
    public static let afterAction = InvariantCheckPoints(rawValue: 1 << 0)
    /// The commit of each turn that touched a key in the rule's `reads`.
    public static let afterTurn = InvariantCheckPoints(rawValue: 1 << 1)
    /// Only `debug.invariants {check: true, ipc: true}`: an IPC or census rule, never inside a turn.
    public static let harness = InvariantCheckPoints(rawValue: 1 << 2)

    /// The names `debug.invariants {rules: true}` lists.
    public var names: [String] {
        [(Self.afterAction, "afterAction"), (Self.afterTurn, "afterTurn"), (Self.harness, "harness")]
            .filter { contains($0.0) }.map(\.1)
    }
}
#endif
