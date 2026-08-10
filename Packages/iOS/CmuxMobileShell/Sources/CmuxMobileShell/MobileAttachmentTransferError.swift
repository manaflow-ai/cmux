internal import CMUXMobileCore
internal import CmuxMobileRPC
internal import CmuxMobileSupport
internal import Foundation

/// Privacy-safe user-facing replacement for attachment protocol failures.
struct MobileAttachmentTransferError: LocalizedError, DiagnosticFailureProviding {
    let diagnosticFailureKind: DiagnosticFailureKind

    var errorDescription: String? {
        L10n.string(
            "mobile.attachment.error.transferFailed",
            defaultValue: "The attachment couldn’t be sent. Try again."
        )
    }

    /// Keeps connection and authorization failures actionable while replacing
    /// host-controlled attachment protocol text with one localized message.
    static func sanitizing(_ error: any Error) -> any Error {
        if error is CancellationError {
            return error
        }
        guard let connectionError = error as? MobileShellConnectionError else {
            return Self(diagnosticFailureKind: DiagnosticFailureKind.classify(error))
        }
        switch connectionError {
        case .invalidResponse:
            return Self(diagnosticFailureKind: connectionError.diagnosticFailureKind)
        case let .rpcError(code, _):
            let normalizedCode = code?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let actionableCodes = [
                "unauthorized", "forbidden", "invalid_token", "token_expired",
                "expired_token", "auth_required", "account_mismatch",
                "unavailable", "request_timeout", "cancelled",
            ]
            guard !actionableCodes.contains(normalizedCode ?? "") else {
                return connectionError
            }
            return Self(diagnosticFailureKind: connectionError.diagnosticFailureKind)
        case .connectionClosed, .requestTimedOut, .transportWriteTimedOut,
             .routeCleanupBlocked, .connectAttemptGated, .insecureManualRoute,
             .attachTicketExpired, .authorizationFailed, .accountMismatch:
            return connectionError
        }
    }
}
