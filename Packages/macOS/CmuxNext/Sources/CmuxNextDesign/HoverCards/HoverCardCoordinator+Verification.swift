import AppKit
import CmuxNextCompat
#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextInvariants
#endif

// The live checks of `HoverCardCoordinator`: H1, declared once in the invariant registry
// (plans/cmux-next/invariants-DESIGN.md).
extension HoverCardCoordinator {
    /// What H1 reads now: the live card windows and what the machine shows.
    public var cardFacts: HoverCardFacts {
        HoverCardFacts(windows: HoverCardPanel.liveInstances.load(ordering: .relaxed), showing: panel?.isShowingCard == true,
                       panelVisible: panel?.isVisible == true, machineTarget: machine.shownTarget?.id.rawValue,
                       owned: owned?.id.rawValue)
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// Declares H1 in `registry`: at most one hover card exists and shows, and it shows the coordinator's target.
    public func declareInvariants(in registry: InvariantRegistry) {
        registry.declare(InvariantRule(
            id: "H1", statement: "at most one hover card exists and shows, and it shows the coordinator's target",
            owner: "HoverCards", reads: [.hover, .focus], points: [.afterAction, .afterTurn], cost: .cheap,
            read: { [weak self] _ in self?.cardFacts },
            check: { facts in facts.violations.map { InvariantFinding(subject: .app, detail: $0) } }))
    }
    #endif
}
