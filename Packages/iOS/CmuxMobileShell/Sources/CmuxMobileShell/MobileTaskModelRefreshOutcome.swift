internal import CmuxMobileRPC
public import CMUXMobileCore

/// The next action after one task model list refresh.
public enum MobileTaskModelRefreshOutcome: Equatable, Sendable {
    /// The host or backend supplied a usable model catalog.
    case succeeded
    /// The failure may recover on a later request.
    case retry(DiagnosticFailureKind)
    /// Another request would repeat a known permanent failure.
    case stopped(DiagnosticTaskModelRetryStopReason)

    /// Classifies only failures with a clear permanent outcome as terminal.
    /// Unknown errors remain retryable so a transient transport or provider
    /// issue cannot strand an open composer.
    public static func classify(_ error: any Error) -> Self {
        if error is CancellationError {
            return .stopped(.cancelled)
        }
        if let error = error as? MobileShellConnectionError {
            switch error {
            case .authorizationFailed:
                return .stopped(.authorizationRequired)
            case .accountMismatch:
                return .stopped(.accountMismatch)
            case .insecureManualRoute:
                return .stopped(.unsupported)
            case .attachTicketExpired:
                return .stopped(.authorizationRequired)
            case .rpcError(let code, _):
                switch code?.lowercased() {
                case "method_not_found", "unknown_method", "unsupported_method":
                    return .stopped(.unsupported)
                case "capability_disabled", "feature_disabled":
                    return .stopped(.disabled)
                case "unauthorized", "forbidden":
                    return .stopped(.authorizationRequired)
                case "account_mismatch":
                    return .stopped(.accountMismatch)
                case "invalid_params":
                    return .stopped(.invalidRequest)
                case "cancelled":
                    return .stopped(.cancelled)
                default:
                    break
                }
            case .invalidResponse, .connectionClosed, .requestTimedOut,
                 .transportWriteTimedOut, .routeCleanupBlocked,
                 .connectAttemptGated:
                break
            }
        }
        return .retry(DiagnosticFailureKind.classify(error))
    }

    /// Maps a terminal decision to the bounded failure vocabulary used by the
    /// ordinary load event. The stop event carries the more precise reason.
    public var diagnosticFailure: DiagnosticFailureKind {
        switch self {
        case .succeeded:
            .none
        case .retry(let failure):
            failure
        case .stopped(let reason):
            switch reason {
            case .unsupported, .disabled, .invalidRequest:
                .protocolViolation
            case .authorizationRequired:
                .authorizationFailed
            case .accountMismatch:
                .accountMismatch
            case .providerUnavailable:
                .endpointUnavailable
            case .cancelled:
                .cancelled
            }
        }
    }
}
