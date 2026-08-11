import CmuxAgentChat
import CmuxMobileRPC
import Foundation
import Testing

@testable import CmuxMobileShell

@Suite
struct MobileChatArtifactFailureClassifierTests {
    @Test
    func reservesMacUnreachableForControlTransportLoss() {
        let classifier = MobileChatArtifactFailureClassifier()

        #expect(classifier.classify(MobileShellConnectionError.connectionClosed) == .macUnreachable)
        #expect(classifier.classify(MobileShellConnectionError.requestTimedOut) == .loadFailed)
        #expect(classifier.classify(MobileShellConnectionError.transportWriteTimedOut) == .loadFailed)
        #expect(classifier.classify(MobileShellConnectionError.invalidResponse) == .loadFailed)
        #expect(classifier.classify(MobileShellConnectionError.connectAttemptGated) == .loadFailed)
        #expect(classifier.classify(CocoaError(.fileReadUnknown)) == .loadFailed)
    }

    @Test
    func preservesServerArtifactFailures() {
        let classifier = MobileChatArtifactFailureClassifier()

        #expect(classifier.classify(MobileShellConnectionError.rpcError("not_found", "gone")) == .sessionNotFound)
        #expect(classifier.classify(MobileShellConnectionError.rpcError("file_not_found", "gone")) == .fileNotFound)
        #expect(classifier.classify(MobileShellConnectionError.rpcError("forbidden", "denied")) == .forbidden)
        #expect(classifier.classify(MobileShellConnectionError.rpcError("unexpected", "bad")) == .loadFailed)
    }
}
