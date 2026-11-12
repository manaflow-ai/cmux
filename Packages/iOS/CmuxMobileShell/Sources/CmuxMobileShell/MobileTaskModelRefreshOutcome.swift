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
    public init(classifying error: any Error) {
        if error is CancellationError {
            self = .stopped(.cancelled)
            return
        }
        if let error = error as? MobileShellConnectionError {
            switch error {
            case .authorizationFailed:
                self = .stopped(.authorizationRequired)
                return
            case .accountMismatch:
                self = .stopped(.accountMismatch)
                return
            case .insecureManualRoute:
                self = .stopped(.unsupported)
                return
            case .attachTicketExpired:
                self = .stopped(.authorizationRequired)
                return
            case .rpcError(let code, _):
                switch code?.lowercased() {
                case "method_not_found", "unknown_method", "unsupported_method":
                    self = .stopped(.unsupported)
                    return
                case "capability_disabled", "feature_disabled":
                    self = .stopped(.disabled)
                    return
                case "unauthorized", "forbidden":
                    self = .stopped(.authorizationRequired)
                    return
                case "account_mismatch":
                    self = .stopped(.accountMismatch)
                    return
                case "invalid_params":
                    self = .stopped(.invalidRequest)
                    return
                case "cancelled":
                    self = .stopped(.cancelled)
                    return
                default:
                    break
                }
            case .invalidResponse, .connectionClosed, .requestTimedOut,
                 .transportWriteTimedOut, .routeCleanupBlocked,
                 .connectAttemptGated:
                break
            }
        }
        self = .retry(DiagnosticFailureKind.classify(error))
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
