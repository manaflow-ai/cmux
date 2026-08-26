import Foundation
import Testing
@testable import CmuxFoundation

@Suite("Remote PTY error code taxonomy")
struct RemotePTYErrorCodeTests {
    @Test("legacy text is normalized into stable retry categories")
    func legacyTextClassification() {
        #expect(
            RemotePTYErrorCode.code(forMessage: "daemon RPC timeout") ==
                RemotePTYErrorCode.timeout.rawValue
        )
        #expect(
            RemotePTYErrorCode.code(forMessage: "remote daemon is not ready") ==
                RemotePTYErrorCode.connectionInactive.rawValue
        )
        #expect(
            RemotePTYErrorCode.code(forMessage: "PTY input queue is full") ==
                RemotePTYErrorCode.inputQueueFull.rawValue
        )
        #expect(
            RemotePTYErrorCode.code(forMessage: "persistent SSH PTY session is not running") ==
                RemotePTYErrorCode.sessionNotFound.rawValue
        )
        #expect(
            RemotePTYErrorCode.code(forMessage: "pty_lifecycle_closed") ==
                RemotePTYErrorCode.lifecycleClosed.rawValue
        )
    }

    @Test("structured codes win over misleading text")
    func structuredCodePrecedence() {
        let error = NSError(
            domain: "cmux.remote.daemon.rpc",
            code: 14,
            userInfo: [
                NSLocalizedDescriptionKey: "pty.attach failed (remote_pty_attach_failed): timed out",
                RemotePTYErrorCode.rpcErrorCodeUserInfoKey: RemotePTYErrorCode.attachFailed.rawValue,
            ]
        )

        #expect(RemotePTYErrorCode.code(for: error) == RemotePTYErrorCode.attachFailed.rawValue)
    }

    @Test("known local transport seams map without reading their text")
    func localTransportSeamsUseStableCategories() {
        #expect(
            RemotePTYErrorCode.code(for: NSError(
                domain: "cmux.remote.daemon.rpc",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "unexpected wording"]
            )) == RemotePTYErrorCode.connectionInactive.rawValue
        )
        #expect(
            RemotePTYErrorCode.code(for: NSError(
                domain: "cmux.remote.pty",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "unexpected wording"]
            )) == RemotePTYErrorCode.timeout.rawValue
        )
        #expect(
            RemotePTYErrorCode.code(for: NSError(
                domain: "cmux.remote.daemon.rpc",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "localized capability text"]
            )) == RemotePTYErrorCode.capabilityMissing.rawValue
        )
    }

    @Test("unknown structured codes are preserved for closed-world consumers")
    func unknownCodeIsNotReclassifiedFromMessage() {
        let error = NSError(
            domain: "cmux.remote.daemon.rpc",
            code: 14,
            userInfo: [
                NSLocalizedDescriptionKey: "remote connection is not active",
                RemotePTYErrorCode.rpcErrorCodeUserInfoKey: "remote_pty_future_transient",
            ]
        )

        #expect(RemotePTYErrorCode.code(for: error) == "remote_pty_future_transient")
        #expect(!RemotePTYErrorCode.isKnown("remote_pty_future_transient"))
    }

    @Test("legacy RPC and PTY not-found envelopes normalize by their message")
    func legacyEnvelopeClassification() {
        #expect(
            RemotePTYErrorCode.code(for: NSError(
                domain: "cmux.remote.daemon.rpc",
                code: 14,
                userInfo: [
                    NSLocalizedDescriptionKey: "pty.attach failed (rpc_error): remote connection is not active",
                    RemotePTYErrorCode.rpcErrorCodeUserInfoKey: "rpc_error",
                ]
            )) == RemotePTYErrorCode.connectionInactive.rawValue
        )
        #expect(
            RemotePTYErrorCode.code(for: NSError(
                domain: "cmux.remote.daemon.rpc",
                code: 14,
                userInfo: [
                    NSLocalizedDescriptionKey: "pty.close failed (not_found): PTY session not found",
                    RemotePTYErrorCode.rpcErrorCodeUserInfoKey: "not_found",
                ]
            )) == RemotePTYErrorCode.sessionNotFound.rawValue
        )
    }
}
