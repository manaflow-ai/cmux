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

    @Test("connection and authorization failures remain actionable")
    func actionableFailuresArePreserved() {
        let connection = MobileAttachmentTransferError.sanitizing(
            MobileShellConnectionError.connectionClosed
        )
        let authorization = MobileAttachmentTransferError.sanitizing(
            MobileShellConnectionError.rpcError("unauthorized", "Sign in again")
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
        #expect(message == "Sign in again")
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
