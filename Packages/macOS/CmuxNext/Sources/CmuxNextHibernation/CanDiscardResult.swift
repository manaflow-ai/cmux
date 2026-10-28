/// Whether content may be discarded for a ``DiscardReason``: Chrome's `CanDiscardResult`
/// (chrome/browser/performance_manager/policies/discard_eligibility_policy.h). Ordered from best to
/// worst; the worst result of the rules that match wins.
package nonisolated enum CanDiscardResult: Int, Hashable, Sendable, Comparable {
    /// Nothing keeps it.
    case eligible
    /// Kept from the discards cmux makes on its own (the rule names which): Chrome's `DiscardAPage`
    /// passes `discard_protected_tabs=false`, so pressure never takes protected content.
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
    /// Seconds until every matched rule stops matching with time alone (``DiscardRule/expires(_:)``):
    /// when the planner looks again. Nil when nothing matched or an event must end one of them.
    package var endsIn: Double?

    package init(result: CanDiscardResult = .eligible, reasons: [CannotDiscardReason] = [], endsIn: Double? = nil) {
        self.result = result
        self.reasons = reasons
        self.endsIn = endsIn
    }

    /// The reason `debug.surfaces` reports: the first rule that matched.
    package var reason: CannotDiscardReason? {
        reasons.first
    }
}
