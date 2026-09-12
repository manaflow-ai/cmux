/// The user-visible lifecycle phase of an irx host activation.
public enum IrxHostActivationState: String, Codable, Equatable, Sendable {
    /// No irx host endpoint is active.
    case inactive
    /// The host is preparing identity, credentials, or endpoint state.
    case activating
    /// The endpoint is ready for iPhone connections.
    case active
    /// A transient failure is waiting on bounded backoff.
    case retrying
    /// A non-retryable activation failure stopped the endpoint.
    case failed
    /// The broker rejected the session after its one refresh attempt.
    case reauthenticationRequired = "reauthentication_required"
}
