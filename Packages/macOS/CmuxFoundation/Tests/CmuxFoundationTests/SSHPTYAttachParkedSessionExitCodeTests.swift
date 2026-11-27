import Testing
@testable import CmuxFoundation

/// https://github.com/manaflow-ai/cmux/issues/12813: when the app reports that
/// the remote session is parked, the attach wrapper must stop instead of
/// spending its whole reconnect budget on a session that cannot become ready.
@Suite("SSH PTY attach parked-session exit code")
struct SSHPTYAttachParkedSessionExitCodeTests {
    /// Parked details are user-facing prose. Several legitimately contain the
    /// phrases the textual classifier treats as transient, so the structured
    /// code, never the wording, has to decide.
    @Test(
        "a parked session is terminal however its detail is worded",
        arguments: [
            "Remote daemon bootstrap failed: Could not prepare the remote daemon. Use Reconnect to try again.",
            "The cmux relay on dev@host did not become ready before the connection timed out. Use Reconnect to try again.",
            "SSH reconnect paused: ssh: connect to host dev port 22: Operation timed out",
            "remote daemon is not ready",
            "connection refused",
        ]
    )
    func parkedSessionIsTerminal(detail: String) {
        let classified = SSHPTYAttachExitCode.classifyBridgeEstablishmentFailure(
            code: "remote_session_parked",
            message: detail
        )

        #expect(classified == .fatal)
        #expect(!classified.isWrapperRetryable)
        #expect(classified.managedRetryStatus(for: detail) == .fatal)
    }

    @Test("the structured code is matched case- and whitespace-insensitively like its peers")
    func parkedCodeIsNormalized() {
        #expect(
            SSHPTYAttachExitCode.classifyBridgeEstablishmentFailure(
                code: " Remote_Session_Parked\n",
                message: "connection timed out"
            ) == .fatal
        )
    }
}
