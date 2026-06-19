import CmuxRemoteDaemon
import Foundation
import Network
import Testing
@testable import CmuxRemoteWorkspace

@Suite("RemotePTYBridgeServer error mapping")
struct RemotePTYBridgeErrorMappingTests {
    /// Builds a session (never started) so the wire-pinned attach-error
    /// mapping can be exercised directly.
    private func makeSession() -> RemotePTYBridgeServer.Session {
        RemotePTYBridgeServer.Session(
            connection: NWConnection(host: "127.0.0.1", port: 65_000, using: .tcp),
            rpcClient: RecordingPTYBridgeRPCClient(),
            sessionID: "s",
            attachmentID: "a",
            command: nil,
            requireExisting: false,
            token: "t",
            queue: DispatchQueue(label: "error-mapping-tests"),
            strings: TestPTYBridgeStrings(),
            clock: SystemRemoteProxyRetryClock(),
            onClose: {}
        )
    }

    private func message(_ text: String) -> NSError {
        NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    @Test(
        "daemon error text maps onto the app-resolved strings by wire-pinned markers",
        arguments: [
            ("daemon: missing required capability pty.write.notification", "test-missing-capability"),
            ("attach failed: pty.session unsupported", "test-missing-capability"),
            ("pty_session_not_found", "test-session-ended"),
            ("persistent SSH PTY session is not running", "test-session-ended"),
            ("pty_input_queue_full", "test-input-backed-up"),
            ("the PTY input queue is full", "test-input-backed-up"),
            ("request timed out", "test-daemon-timeout"),
            ("connection timeout while attaching", "test-daemon-timeout"),
            ("some completely unexpected failure", "test-attach-failed"),
        ]
    )
    func mapsMarkersToStrings(text: String, expected: String) {
        let session = makeSession()
        #expect(session.userFacingBridgeErrorMessage(message(text)) == expected)
    }

    @Test("the PTY-allocation diagnostic passes the trimmed daemon text through")
    func allocationDiagnosticPassesMessageThrough() {
        let session = makeSession()
        let mapped = session.userFacingBridgeErrorMessage(
            message("  could not allocate a remote PTY: /dev/pts/3 (ptmxmode)  ")
        )
        #expect(mapped == "diag:could not allocate a remote PTY: /dev/pts/3 (ptmxmode)")
    }

    @Test("capability markers win over timeout markers (legacy precedence)")
    func capabilityPrecedesTimeout() {
        let session = makeSession()
        let mapped = session.userFacingBridgeErrorMessage(
            message("pty.session attach timed out")
        )
        #expect(mapped == "test-missing-capability")
    }
}

@Suite("ListenerStartupState")
struct ListenerStartupStateTests {
    @Test("records the ready port for the blocked caller")
    func recordsReadyPort() {
        let state = ListenerStartupState()
        state.recordReady(port: 4321)
        let outcome = state.snapshot()
        #expect(outcome.port == 4321)
        #expect(outcome.failure == nil)
    }

    @Test("records a startup failure for the blocked caller")
    func recordsFailure() {
        let state = ListenerStartupState()
        state.recordFailure(NSError(domain: "test", code: 9))
        let outcome = state.snapshot()
        #expect(outcome.port == nil)
        #expect((outcome.failure as? NSError)?.code == 9)
    }
}
