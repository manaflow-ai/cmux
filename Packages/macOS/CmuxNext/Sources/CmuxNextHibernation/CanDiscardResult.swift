/// Whether content may be discarded for a ``DiscardReason``: Chrome's `CanDiscardResult`
/// (chrome/browser/performance_manager/policies/discard_eligibility_policy.h). Ordered from best to
/// worst; the worst result of the rules that match wins.
package nonisolated enum CanDiscardResult: Int, Hashable, Sendable, Comparable {
    /// Nothing keeps it.
    case eligible
    /// Kept from proactive and urgent discards: Chrome's `DiscardAPage` passes
    /// `discard_protected_tabs=false`, so pressure never takes protected content.
    case protected
    /// Kept from every discard, even one the person asked for.
    case disallowed

    package static func < (lhs: CanDiscardResult, rhs: CanDiscardResult) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One candidate's answer from ``ContentDiscardPlanner/eligibility(of:setting:for:)``: the worst
/// result and every reason that matched, in rule order (Chrome fills `cannot_discard_reasons` the
/// same way).
package nonisolated struct DiscardEligibility: Hashable, Sendable {
    /// The worst result of the matched rules.
    package var result: CanDiscardResult
    /// The matched rules' reasons, in registration order.
    package var reasons: [CannotDiscardReason]

    package init(result: CanDiscardResult = .eligible, reasons: [CannotDiscardReason] = []) {
        self.result = result
        self.reasons = reasons
    }

    /// The reason `debug.surfaces` reports: the first rule that matched.
    package var reason: CannotDiscardReason? {
        reasons.first
    }
}
