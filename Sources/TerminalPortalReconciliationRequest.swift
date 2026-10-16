import CMUXMobileCore

/// Coalesced portal work and the transition attached to its diagnostic interval.
struct TerminalPortalReconciliationRequest {
    var reasons: TerminalPortalReconciliationReasons

    var transition: TerminalWorkContext.Transition = .unknown

    /// Generic callbacks add work without erasing an established origin.
    /// A later explicit transition represents the newest originating action.
    mutating func merge(
        reasons: TerminalPortalReconciliationReasons,
        transition: TerminalWorkContext.Transition
    ) {
        self.reasons.formUnion(reasons)
        if transition != .unknown { self.transition = transition }
    }
}
