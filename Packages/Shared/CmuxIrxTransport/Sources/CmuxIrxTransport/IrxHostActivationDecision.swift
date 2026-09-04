public import Foundation

/// The lifecycle action selected for one classified irx activation failure.
public enum IrxHostActivationDecision: Equatable, Sendable {
    /// Retry after the supplied bounded delay, preserving a broker floor.
    case retry(delay: TimeInterval, retryAfterSeconds: Int?)
    /// Stop the endpoint and ask the account owner to authenticate again.
    case reauthenticationRequired
    /// Stop because the failure is not safely retryable.
    case stopped
}
