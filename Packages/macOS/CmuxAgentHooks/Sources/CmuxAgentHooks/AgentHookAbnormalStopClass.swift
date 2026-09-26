/// Stable provider failure classes that terminate a turn without completing it.
/// The enum is deliberately UI-neutral so hook consumers can share the
/// classification contract without importing the app target.
public enum AgentHookAbnormalStopClass: Equatable, Sendable, CaseIterable {
    /// The provider cannot accept work because its model or service is full.
    case capacity
    /// The provider account has exhausted its usage allowance.
    case quota
    /// The provider rejected the request for exceeding a request-rate limit.
    case rateLimit
    /// The provider did not complete the request before its deadline.
    case timeout
    /// The provider credentials or session are not accepted.
    case authentication
    /// The provider connection became unavailable.
    case network
    /// A provider failure was reported without a more specific category.
    case generic
}
