import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing

@testable import CmuxMobileShell

@Suite("Mobile attachment transfer errors")
struct MobileAttachmentTransferErrorTests {
    private struct PrivateUnrelatedError: LocalizedError, DiagnosticFailureProviding {
        var errorDescription: String? {
            "permission denied for /Users/private/secret.png"
        }

        var diagnosticFailureKind: DiagnosticFailureKind { .permissionDenied }
    }

    @Test("protocol failures hide host messages and retain diagnostic classification")
    func protocolFailureIsPrivacySafe() throws {
        let rawMessage = "operation_id does not match staging root /Users/private"
        let error = MobileAttachmentTransferError.sanitizing(
            MobileShellConnectionError.rpcError("invalid_params", rawMessage)
        )

        let sanitized = try #require(error as? MobileAttachmentTransferError)
        #expect(sanitized.diagnosticFailureKind == .protocolViolation)
        #expect(!sanitized.localizedDescription.contains("operation_id"))
        #expect(!sanitized.localizedDescription.contains("/Users/private"))
        #expect(sanitized.localizedDescription == "The attachment couldn’t be sent. Try again.")
    }

    @Test("connection and RPC codes remain actionable without preserving host copy")
    func actionableConnectionAndRPCCodeArePrivacySafe() {
        let rawMessage = "renew token stored at /Users/private/session.json"
        let connection = MobileAttachmentTransferError.sanitizing(
            MobileShellConnectionError.connectionClosed
        )
        let authorization = MobileAttachmentTransferError.sanitizing(
            MobileShellConnectionError.rpcError("unauthorized", rawMessage)
        )
        let accountMismatch = MobileAttachmentTransferError.sanitizing(
            MobileShellConnectionError.rpcError("account_mismatch", rawMessage)
        )
        let timeout = MobileAttachmentTransferError.sanitizing(
            MobileShellConnectionError.rpcError("request_timeout", rawMessage)
        )

        guard let connection = connection as? MobileShellConnectionError,
              case .connectionClosed = connection else {
            Issue.record("connection error classification was replaced")
            return
        }
        guard let authorization = authorization as? MobileShellConnectionError,
              case .rpcError(let code, let message) = authorization else {
            Issue.record("authorization error classification was replaced")
            return
        }
        #expect(code == "unauthorized")
        #expect(message == "Sign in again to send this attachment.")
        #expect(!message.contains("/Users/private"))
        #expect(!message.contains("session.json"))
        guard let accountMismatch = accountMismatch as? MobileShellConnectionError,
              case .rpcError(let accountCode, let accountMessage) = accountMismatch,
              let timeout = timeout as? MobileShellConnectionError,
              case .rpcError(let timeoutCode, let timeoutMessage) = timeout else {
            Issue.record("actionable RPC codes were replaced")
            return
        }
        #expect(accountCode == "account_mismatch")
        #expect(
            accountMessage
                == "Sign in to the same cmux account on this device and Mac to send attachments."
        )
        #expect(timeoutCode == "request_timeout")
        #expect(timeoutMessage == "The attachment couldn’t be sent. Try again.")
        #expect(!accountMessage.contains("/Users/private"))
        #expect(!timeoutMessage.contains("/Users/private"))
    }

    @Test("authorization and account mismatch cases replace associated private copy")
    func actionableAssociatedMessagesArePrivacySafe() {
        let rawMessage = "account token mismatch in /Users/private/auth.json"
        let authorization = MobileAttachmentTransferError.sanitizing(
            MobileShellConnectionError.authorizationFailed(rawMessage)
        )
        let accountMismatch = MobileAttachmentTransferError.sanitizing(
            MobileShellConnectionError.accountMismatch(rawMessage)
        )

        guard let authorization = authorization as? MobileShellConnectionError,
              case .authorizationFailed(let authorizationMessage) = authorization else {
            Issue.record("authorization case was replaced")
            return
        }
        guard let accountMismatch = accountMismatch as? MobileShellConnectionError,
              case .accountMismatch(let accountMessage) = accountMismatch else {
            Issue.record("account mismatch case was replaced")
            return
        }
        #expect(authorizationMessage == "Sign in again to send this attachment.")
        #expect(
            accountMessage
                == "Sign in to the same cmux account on this device and Mac to send attachments."
        )
        for safeMessage in [authorizationMessage, accountMessage] {
            #expect(!safeMessage.contains("/Users/private"))
            #expect(!safeMessage.contains("auth.json"))
        }
    }

    @Test("cancellation passes through without becoming an attachment failure")
    func cancellationPassesThrough() {
        let sanitized = MobileAttachmentTransferError.sanitizing(CancellationError())

        #expect(sanitized is CancellationError)
        #expect(!(sanitized is MobileAttachmentTransferError))
    }

    @Test("unrelated failures retain only a privacy-safe classification")
    func unrelatedFailureIsClassifiedWithoutPrivateCopy() throws {
        let sanitizedError = MobileAttachmentTransferError.sanitizing(
            PrivateUnrelatedError()
        )
        let sanitized = try #require(
            sanitizedError as? MobileAttachmentTransferError
        )

        #expect(sanitized.diagnosticFailureKind == .permissionDenied)
        #expect(sanitized.localizedDescription == "The attachment couldn’t be sent. Try again.")
        #expect(!sanitized.localizedDescription.contains("permission denied"))
        #expect(!sanitized.localizedDescription.contains("/Users/private"))
    }
}
