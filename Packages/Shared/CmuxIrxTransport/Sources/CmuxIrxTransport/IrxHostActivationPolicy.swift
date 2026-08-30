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
    private static let defaultPostRecoveryUnauthorizedFailureLimit = 2
    private static let defaultMissingAuthenticationFailureLimit = 2

    /// The first and maximum retry bounds used by an irx host.
    public let retrySchedule: CmxIrohRetrySchedule
    private let postRecoveryUnauthorizedFailureLimit: Int
    private let missingAuthenticationFailureLimit: Int

    /// The outcome of classifying one activation failure.
    public enum Decision: Equatable, Sendable {
        case retry(delay: TimeInterval, retryAfterSeconds: Int?)
        case reauthenticationRequired
        case stopped
    }

    /// Creates an activation policy.
    public init(
        retrySchedule: CmxIrohRetrySchedule = .foregroundClient,
        postRecoveryUnauthorizedFailureLimit: Int =
            Self.defaultPostRecoveryUnauthorizedFailureLimit,
        missingAuthenticationFailureLimit: Int =
            Self.defaultMissingAuthenticationFailureLimit
    ) {
        self.retrySchedule = retrySchedule
        self.postRecoveryUnauthorizedFailureLimit = max(
            1, min(20, postRecoveryUnauthorizedFailureLimit))
        self.missingAuthenticationFailureLimit = max(
            1, min(20, missingAuthenticationFailureLimit))
    }

    /// Classifies a failure and computes its next bounded retry delay.
    ///
    /// - Parameters:
    ///   - error: The broker or local activation failure.
    ///   - failureCount: Consecutive failures, starting at zero.
    ///   - jitterUnitInterval: A deterministic value from zero through one.
    ///   - escalateUnauthorized: Whether repeated post-recovery auth failures
    ///     should transition to reauthentication. Auxiliary lanes can disable
    ///     escalation while still supplying their local count for backoff.
    /// - Returns: A terminal re-authentication/stop decision or a bounded retry.
    public func decision(
        for error: any Error,
        failureCount: Int,
        jitterUnitInterval: Double,
        escalateUnauthorized: Bool = true
    ) -> Decision {
        let failure = error as? IrxBrokerFailure
            ?? IrxBrokerFailure(operation: .register, error: error)
        // A final 401 after the shared one-refresh recovery can be a short
        // propagation race, so allow a small bounded retry window. It must
        // still escalate rather than rebuilding the endpoint forever when the
        // broker persistently rejects the rotated pair.
        if escalateUnauthorized,
           failure.statusCode == 401,
           failureCount >= postRecoveryUnauthorizedFailureLimit {
            return .reauthenticationRequired
        }
        if escalateUnauthorized,
           failure.statusCode == nil,
           failure.errorCode == "missing_authentication",
           failureCount >= missingAuthenticationFailureLimit {
            return .reauthenticationRequired
        }
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
