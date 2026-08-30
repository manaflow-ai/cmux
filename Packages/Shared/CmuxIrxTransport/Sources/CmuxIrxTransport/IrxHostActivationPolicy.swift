public import CmuxIrohTransport
public import Foundation

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

/// Decides whether a failed activation retries, stops, or requires sign-in.
///
/// The policy is deliberately value-typed and clock-free. The host lifecycle
/// owns the injected ``CmxIrohRelayClock`` and performs the cancellable wait;
/// this type only derives a bounded delay from the classified broker result.
public struct IrxHostActivationPolicy: Equatable, Sendable {
    /// The first and maximum retry bounds used by an irx host.
    public let retrySchedule: CmxIrohRetrySchedule

    /// The outcome of classifying one activation failure.
    public enum Decision: Equatable, Sendable {
        case retry(delay: TimeInterval, retryAfterSeconds: Int?)
        case reauthenticationRequired
        case stopped
    }

    /// Creates an activation policy.
    public init(
        retrySchedule: CmxIrohRetrySchedule = .foregroundClient
    ) {
        self.retrySchedule = retrySchedule
    }

    /// Classifies a failure and computes its next bounded retry delay.
    ///
    /// - Parameters:
    ///   - error: The broker or local activation failure.
    ///   - failureCount: Consecutive failures, starting at zero.
    ///   - jitterUnitInterval: A deterministic value from zero through one.
    /// - Returns: A terminal re-authentication/stop decision or a bounded retry.
    public func decision(
        for error: any Error,
        failureCount: Int,
        jitterUnitInterval: Double
    ) -> Decision {
        let failure = error as? IrxBrokerFailure
            ?? IrxBrokerFailure(operation: .register, error: error)
        if failure.requiresReauthentication {
            return .reauthenticationRequired
        }
        guard failure.isRetryable else { return .stopped }
        let delay = retrySchedule.delay(
            failureCount: failureCount,
            retryAfterSeconds: failure.retryAfterSeconds,
            jitterUnitInterval: jitterUnitInterval
        )
        return .retry(
            delay: delay,
            retryAfterSeconds: failure.retryAfterSeconds
        )
    }
}
