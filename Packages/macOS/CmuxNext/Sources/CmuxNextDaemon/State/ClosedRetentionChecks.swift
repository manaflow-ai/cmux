/// Which machines a closed history retention check reads (p06-scheduler.md R-index): the ones whose closed
/// list revision (`SessionStateStore.closedRevision`) moved since their last check, a machine that just
/// connected, and every one when the limits changed. A machine whose list did not change is not read again.
public struct ClosedRetentionChecks: Sendable, Equatable {
    /// The limits of the last state.
    public private(set) var limits = ClosedRetention(maxGroups: 0, maxAgeDays: 0)
    /// The closed list revision each connected machine was last checked at.
    private var checked: [String: UInt64] = [:]

    public init() {}

    /// Moves to `limits` and `machines` (each connected machine's closed list revision) and returns the
    /// machines to check now. A machine no longer in `machines` is forgotten.
    public mutating func advance(limits: ClosedRetention, machines: [String: UInt64]) -> Set<String> {
        let limitsChanged = limits != self.limits
        self.limits = limits
        let changed = machines.filter { limitsChanged || checked[$0.key] != $0.value }
        checked = machines
        return Set(changed.keys)
    }
}
