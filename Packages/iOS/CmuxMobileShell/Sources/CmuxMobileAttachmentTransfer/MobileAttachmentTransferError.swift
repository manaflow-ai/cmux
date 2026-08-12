package import CMUXMobileCore
internal import CmuxMobileRPC
internal import CmuxMobileSupport
internal import Foundation

/// Privacy-safe user-facing replacement for attachment protocol failures.
package struct MobileAttachmentTransferError: LocalizedError, DiagnosticFailureProviding {
    package let diagnosticFailureKind: DiagnosticFailureKind

    package var errorDescription: String? {
        Self.transferFailureMessage
    }

    /// Keeps connection and authorization failures actionable while replacing
    /// host-controlled attachment protocol text with one localized message.
    package static func sanitizing(_ error: any Error) -> any Error {
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
                return MobileShellConnectionError.rpcError(
                    code,
                    safeRPCMessage(for: normalizedCode)
                )
            }
            return Self(diagnosticFailureKind: connectionError.diagnosticFailureKind)
        case .authorizationFailed:
            return MobileShellConnectionError.authorizationFailed(
                authorizationFailureMessage
            )
        case .accountMismatch:
            return MobileShellConnectionError.accountMismatch(
                accountMismatchMessage
            )
        case .connectionClosed, .requestTimedOut, .transportWriteTimedOut,
             .routeCleanupBlocked, .connectAttemptGated, .insecureManualRoute,
             .attachTicketExpired:
            return connectionError
        }
    }

    private static func safeRPCMessage(for normalizedCode: String?) -> String {
        switch normalizedCode {
        case "unauthorized", "forbidden", "invalid_token", "token_expired",
             "expired_token", "auth_required":
            authorizationFailureMessage
        case "account_mismatch":
            accountMismatchMessage
        default:
            transferFailureMessage
        }
    }

    private static var transferFailureMessage: String {
        L10n.string(
            "mobile.attachment.error.transferFailed",
            defaultValue: "The attachment couldn’t be sent. Try again."
        )
    }

    private static var authorizationFailureMessage: String {
        L10n.string(
            "mobile.attachment.error.authorizationFailed",
            defaultValue: "Sign in again to send this attachment."
        )
    }

    private static var accountMismatchMessage: String {
        L10n.string(
            "mobile.attachment.error.accountMismatch",
            defaultValue: "Sign in to the same cmux account on this device and Mac to send attachments."
        )
    }
}
