/// How the intents of a ``DaemonStore`` left its log, since the store was made (``DaemonStore/intentTotals``).
/// The totals only grow: a reader takes two readings and compares the difference (the oracle's `intents`
/// facet, whose runner diffs two checkpoints as Chromium's `base::HistogramTester` diffs
/// histogram samples since its creation, base/test/metrics/histogram_tester.h).
///
/// Each intent leaves the log exactly once (``IntentSettlement``), so it counts once: in ``applied`` or in
/// ``rolledBack``.
public struct IntentTotals: Sendable, Hashable {
    /// Intents that left on the daemon's echo of their transaction or once the store applied every
    /// event up to their settle sequence.
    public internal(set) var applied = 0
    /// Intents whose command failed: the store took their change back (``DaemonStore/rejectIntent(_:)``).
    public internal(set) var rolledBack = 0
    /// The case name (``Intent/caseName``) of the last intent rolled back, never its payload, which can
    /// hold a tab, pane or workspace name.
    public internal(set) var lastRolledBack: String?

    public init() {}

    /// These totals with `settlements` counted, each with the intent that left.
    func adding(_ settlements: some Sequence<(IntentSettlement, Intent)>) -> IntentTotals {
        var totals = self
        for (settlement, intent) in settlements {
            switch settlement {
            case .echoed, .applied:
                totals.applied += 1
            case .rejected:
                totals.rolledBack += 1
                totals.lastRolledBack = intent.caseName
            }
        }
        return totals
    }
}
