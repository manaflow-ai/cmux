public import CMUXMobileCore
internal import CmuxMobileSupport
public import Foundation

/// Errors surfaced while connecting to or talking with a paired Mac over the
/// mobile-sync RPC transport.
public enum MobileShellConnectionError: LocalizedError, DiagnosticFailureProviding {
    /// The server returned a response that could not be parsed.
    case invalidResponse
    /// The persistent transport closed.
    case connectionClosed
    /// A request exceeded its timeout deadline.
    case requestTimedOut
    /// A request timed out while its frame was blocked in the transport write.
    case transportWriteTimedOut
    /// A manual host did not advertise a secure route.
    case insecureManualRoute
    /// The attach ticket expired and no fallback was available.
    case attachTicketExpired
    /// Authorization failed; the associated value is a user-facing message.
    case authorizationFailed(String)
    /// The Mac is signed in to a different cmux account than this device. The
    /// associated value is a user-facing message; the caller should drive a
    /// re-authentication flow into the owner's account rather than retry.
    case accountMismatch(String)
    /// A server-reported RPC error: optional code plus a message.
    case rpcError(String?, String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid mobile sync response"
        case .connectionClosed:
            return "Mobile sync connection closed"
        case .requestTimedOut, .transportWriteTimedOut:
            return L10n.string(
                "mobile.connection.requestTimedOut",
                defaultValue: "Mobile sync request timed out"
            )
        case .insecureManualRoute:
            return "Manual host did not advertise a secure mobile sync route"
        case .attachTicketExpired:
            return "Mobile attach ticket expired"
        case let .authorizationFailed(message):
            return message
        case let .accountMismatch(message):
            return message
        case let .rpcError(_, message):
            return message
        }
    }

    public var diagnosticFailureKind: DiagnosticFailureKind {
        switch self {
        case .invalidResponse, .rpcError:
            .protocolViolation
        case .connectionClosed:
            .connectionClosed
        case .requestTimedOut, .transportWriteTimedOut:
            .timedOut
        case .insecureManualRoute:
            .unsupportedRoute
        case .attachTicketExpired:
            .credentialUnavailable
        case .authorizationFailed:
            .authorizationFailed
        case .accountMismatch:
            .accountMismatch
        }
    }
}
