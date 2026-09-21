import CMUXMobileCore

/// Coalesced portal work and the transition attached to its diagnostic interval.
struct TerminalPortalReconciliationRequest {
    var reasons: TerminalPortalReconciliationReasons

    var transition: TerminalWorkContext.Transition {
        reasons.contains(.bindingRequired) ? .reveal : .unknown
    }
}
