import CmuxAgentChat
import CmuxMobileRPC
import Foundation
import Testing

@testable import CmuxMobileShell

@Suite
struct MobileChatArtifactFailureClassifierTests {
    @Test
    func reservesMacUnreachableForControlTransportLoss() {
        let classifier = MobileArtifactFailureClassifier()

        #expect(classifier.classify(MobileShellConnectionError.connectionClosed) == .macUnreachable)
        #expect(classifier.classify(MobileShellConnectionError.requestTimedOut) == .requestTimedOut)
        #expect(classifier.classify(MobileShellConnectionError.transportWriteTimedOut) == .requestTimedOut)
        #expect(classifier.classify(MobileShellConnectionError.invalidResponse) == .invalidResponse)
        #expect(classifier.classify(MobileShellConnectionError.connectAttemptGated) == .connectionRecovering)
        #expect(classifier.classify(MobileShellConnectionError.routeCleanupBlocked) == .connectionNeedsRestart)
        #expect(classifier.classify(MobileShellConnectionError.insecureManualRoute) == .secureConnectionRequired)
        #expect(classifier.classify(MobileShellConnectionError.attachTicketExpired) == .authenticationExpired)
        #expect(classifier.classify(MobileShellConnectionError.authorizationFailed("denied")) == .authorizationFailed)
        #expect(classifier.classify(MobileShellConnectionError.accountMismatch("wrong account")) == .accountMismatch)
        #expect(classifier.classify(CocoaError(.fileReadUnknown)) == .loadFailed)
    }

    @Test
    func preservesServerArtifactFailures() {
        let classifier = MobileArtifactFailureClassifier()

        let exactCodes: [(String, ChatArtifactError)] = [
            ("invalid_params", .invalidParams),
            ("session_not_found", .sessionNotFound),
            ("session_unavailable", .sessionUnavailable),
            ("terminal_not_found", .terminalNotFound),
            ("workspace_not_found", .workspaceNotFound),
            ("not_a_repo", .notRepository),
            ("forbidden", .forbidden),
            ("file_not_found", .fileNotFound),
            ("permission_denied", .permissionDenied),
            ("not_directory", .notDirectory),
            ("not_regular_file", .notRegularFile),
            ("read_failed", .fileReadFailed),
            ("file_changed", .fileChanged),
            ("unsupported_media", .unsupportedMedia),
            ("corrupt_media", .corruptMedia),
            ("preview_failed", .previewFailed),
            ("unavailable", .unavailable),
            ("invalid_response", .invalidResponse),
            ("transfer_interrupted", .transferInterrupted),
            ("request_timed_out", .requestTimedOut),
            ("unsupported_transport", .secureConnectionRequired),
            ("method_not_found", .unsupported),
            ("capability_disabled", .unsupported),
        ]
        for (code, expected) in exactCodes {
            #expect(classifier.classify(
                MobileShellConnectionError.rpcError(code, "fixture")
            ) == expected)
        }

        #expect(classifier.classify(
            MobileShellConnectionError.rpcError("not_found", "gone"),
            method: "mobile.chat.artifact.stat"
        ) == .sessionNotFound)
        #expect(classifier.classify(
            MobileShellConnectionError.rpcError("not_found", "gone"),
            method: "mobile.terminal.artifact.stat"
        ) == .terminalNotFound)
        #expect(classifier.classify(
            MobileShellConnectionError.rpcError("not_found", "gone"),
            method: "mobile.workspace.changes.file_stat"
        ) == .workspaceNotFound)
        #expect(classifier.classify(
            MobileShellConnectionError.rpcError("not_found", "gone")
        ) == .sessionNotFound)
        #expect(classifier.classify(MobileShellConnectionError.rpcError("unexpected", "bad")) == .loadFailed)
    }

    @Test
    func preservesTypedAndDecodeFailures() {
        let classifier = MobileArtifactFailureClassifier()
        let decodeFailure = DecodingError.dataCorrupted(.init(
            codingPath: [],
            debugDescription: "fixture"
        ))

        #expect(classifier.classify(ChatArtifactError.fileChanged) == .fileChanged)
        #expect(classifier.classify(decodeFailure) == .invalidResponse)
    }
}
