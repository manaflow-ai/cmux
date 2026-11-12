/// How a Cloud enable attempt settled.
public enum CloudEnableResult: String, Sendable, CaseIterable {
    case success
    case requiresPaidPlan = "requires_paid_plan"
    case signInRequired = "sign_in_required"
    case serviceUnavailable = "service_unavailable"
    /// Managed policy or rollout made Cloud unavailable.
    case unavailable
    case cancelled
}
