import Testing
@testable import CmuxFoundation

@Suite("SSH PTY attach exit code")
struct SSHPTYAttachExitCodeTests {
    @Test("structured daemon capacity is retryable")
    func structuredUnavailableIsRetryable() {
        #expect(
            SSHPTYAttachExitCode.classifyBridgeEstablishmentFailure(
                code: "unavailable",
                message: "remote PTY attach failed"
            ) == .retryableTransient
        )
        #expect(SSHPTYAttachExitCode.retryableTransient.rawValue == 255)
    }

    @Test("lifecycle codes retain precedence over transient-looking messages")
    func lifecycleCodesRetainPrecedence() {
        #expect(
            SSHPTYAttachExitCode.classifyBridgeEstablishmentFailure(
                code: "pty_session_not_found",
                message: "service unavailable"
            ) == .sessionNotFound
        )
        #expect(
            SSHPTYAttachExitCode.classifyBridgeEstablishmentFailure(
                code: "pty_lifecycle_closed",
                message: "service unavailable"
            ) == .fatal
        )
    }

    @Test("unrelated codes containing unavailable remain fatal")
    func unavailableMustBeExact() {
        #expect(
            SSHPTYAttachExitCode.classifyBridgeEstablishmentFailure(
                code: "service_unavailable",
                message: "remote PTY attach failed"
            ) == .fatal
        )
    }
}
