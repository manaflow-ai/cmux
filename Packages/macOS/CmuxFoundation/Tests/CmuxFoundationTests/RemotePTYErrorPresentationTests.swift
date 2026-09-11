import Foundation
import Testing
@testable import CmuxFoundation

@Suite("Remote PTY error presentation")
struct RemotePTYErrorPresentationTests {
    @Test("legacy markers resolve to stable presentation categories")
    func legacyMarkersResolve() {
        #expect(
            RemotePTYErrorPresentation(message: "missing required capability: pty.session", code: nil).kind ==
                .capabilityMissing
        )
        #expect(
            RemotePTYErrorPresentation(message: "persistent SSH PTY session is not running", code: nil).kind ==
                .sessionNotFound
        )
        #expect(
            RemotePTYErrorPresentation(message: "PTY input queue is full", code: nil).kind ==
                .inputQueueFull
        )
        #expect(
            RemotePTYErrorPresentation(message: "remote daemon tunnel is not ready", code: nil).kind ==
                .daemonNotReady
        )
        #expect(
            RemotePTYErrorPresentation(message: "missing workspace_id in SSH PTY session list response", code: nil).kind ==
                .missingWorkspaceID
        )
        #expect(
            RemotePTYErrorPresentation(message: "missing session_id in SSH PTY session list response", code: nil).kind ==
                .missingSessionID
        )
        #expect(
            RemotePTYErrorPresentation(message: "request timeout", code: nil).kind == .timeout
        )
    }

    @Test("structured codes resolve neutral diagnostics")
    func structuredCodesResolve() {
        #expect(
            RemotePTYErrorPresentation(message: "transport failed", code: "remote_pty_capability_missing").kind ==
                .capabilityMissing
        )
        #expect(
            RemotePTYErrorPresentation(message: "transport failed", code: "pty_session_not_found").kind ==
                .sessionNotFound
        )
        #expect(
            RemotePTYErrorPresentation(message: "transport failed", code: "pty_input_queue_full").kind ==
                .inputQueueFull
        )
        #expect(
            RemotePTYErrorPresentation(message: "transport failed", code: "remote_connection_inactive").kind ==
                .connectionInactive
        )
        #expect(
            RemotePTYErrorPresentation(message: "transport failed", code: "remote_pty_timeout").kind == .timeout
        )
    }

    @Test("structured codes override conflicting legacy text")
    func structuredCodesOverrideLegacyText() {
        #expect(
            RemotePTYErrorPresentation(message: "request timeout", code: "remote_pty_attach_failed").kind ==
                .generic
        )
        #expect(
            RemotePTYErrorPresentation(
                message: "missing required capability: pty.session",
                code: "remote_pty_timeout"
            ).kind == .timeout
        )
        #expect(
            RemotePTYErrorPresentation(message: "", code: "remote_pty_timeout").kind == .timeout
        )
    }

    @Test("unknown structured failures use the generic category")
    func unknownStructuredFailuresAreGeneric() {
        #expect(
            RemotePTYErrorPresentation(message: "transport failed", code: "REMOTE_PTY_TIMEOUT").kind == .generic
        )
        #expect(
            RemotePTYErrorPresentation(message: "request timeout", code: "future_code").kind == .generic
        )
    }

    @Test("legacy envelopes retain message classification")
    func legacyEnvelopesRetainMessageClassification() {
        #expect(
            RemotePTYErrorPresentation(message: "request timeout", code: "remote_pty_error").kind == .timeout
        )
        #expect(
            RemotePTYErrorPresentation(
                message: "remote daemon tunnel is not ready",
                code: "rpc_error"
            ).kind == .daemonNotReady
        )
    }

    @Test("error initializer preserves structured code precedence")
    func errorInitializerUsesStructuredCode() {
        let error = NSError(
            domain: "cmux.remote.daemon.rpc",
            code: 14,
            userInfo: [
                NSLocalizedDescriptionKey: "transport failed",
                RemotePTYErrorCode.rpcErrorCodeUserInfoKey: RemotePTYErrorCode.timeout.rawValue,
            ]
        )

        #expect(RemotePTYErrorPresentation(error: error).kind == .timeout)
    }

    @Test("error initializer falls back to legacy text without metadata")
    func errorInitializerFallsBackToLegacyTextWithoutMetadata() {
        let error = NSError(
            domain: "cmux.remote.daemon.rpc",
            code: 14,
            userInfo: [NSLocalizedDescriptionKey: "missing session_id in SSH PTY session list response"]
        )

        #expect(RemotePTYErrorPresentation(error: error).kind == .missingSessionID)
    }

    @Test("error initializer uses a transport seam when its text is generic")
    func errorInitializerUsesTransportSeamForGenericText() {
        let error = NSError(
            domain: "cmux.remote.daemon.rpc",
            code: 11,
            userInfo: [NSLocalizedDescriptionKey: "transport failed"]
        )

        #expect(RemotePTYErrorPresentation(error: error).kind == .timeout)
    }
}
