/// State of the account-private live-session projection returned with the
/// current team's device registry.
public enum MobileFirstConnectionRegistryState: Equatable, Sendable {
    /// The initial registry request has not completed.
    case loading
    /// The team registry loaded and indicates whether this account has a live session.
    case loaded(hasAccountSession: Bool)
    /// The registry rejected the current account or team authorization.
    case authRejected
    /// The registry could not provide an authoritative response.
    case unavailable
}
