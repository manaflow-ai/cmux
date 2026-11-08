import CmuxMobileTransport
import CmuxMobileRPC
import Foundation

func secondaryControlAttemptIsTransient(_ error: any Error) -> Bool {
    if error is CancellationError || error is DecodingError {
        return false
    }
    if let transportError = error as? CmxNetworkByteTransportError {
        switch transportError {
        case .emptyHost, .invalidPort, .invalidMaximumReceiveLength,
             .unsupportedRouteKind, .unsupportedEndpoint,
             .authorizationIntentRequired, .unsupportedAuthorizationMode,
             .tailscaleAuthorizationUnavailable:
            return false
        case .notConnected, .alreadyClosed, .receiveAlreadyInProgress,
             .sendAlreadyInProgress, .connectionTimedOut, .connectionFailed,
             .receiveFailed, .sendFailed:
            return true
        }
    }
    if let urlError = error as? URLError {
        switch urlError.code {
        case .cancelled, .badURL, .unsupportedURL, .cannotDecodeContentData,
             .cannotDecodeRawData, .cannotParseResponse:
            return false
        default:
            return true
        }
    }
    guard let connectionError = error as? MobileShellConnectionError else {
        return true
    }
    switch connectionError {
    case .connectionClosed, .requestTimedOut, .transportWriteTimedOut,
         .routeCleanupBlocked:
        return true
    case .invalidResponse, .connectAttemptGated, .insecureManualRoute,
         .attachTicketExpired, .authorizationFailed, .accountMismatch:
        return false
    case let .rpcError(code, _):
        let permanentCodes: Set<String> = [
            "account_mismatch",
            "build_incompatible",
            "forbidden",
            "invalid_ticket",
            "invalid_params",
            "method_not_found",
            "ticket_expired",
            "unauthorized",
            "unknown_method",
            "unsupported_version",
            "unsupported_method",
        ]
        return !permanentCodes.contains(code?.lowercased() ?? "")
    }
}
