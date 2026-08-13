import CmuxAgentChat
import Foundation
import Testing
@testable import CmuxAgentChatUI

/// Every artifact failure must surface its own accurate state; only genuine
/// transport failures may present as "Mac unreachable".
@MainActor
struct ChatArtifactViewerErrorStateTests {
    private func state(_ error: any Error, stat: ChatArtifactStat? = nil) -> ChatArtifactViewerState {
        ChatArtifactViewerModel.state(for: error, stat: stat)
    }

    @Test func everyArtifactErrorMapsToItsOwnState() {
        #expect(state(ChatArtifactError.fileNotFound) == .fileMissing)
        #expect(state(ChatArtifactError.forbidden) == .forbidden)
        #expect(state(ChatArtifactError.macUnreachable) == .macUnreachable)
        #expect(state(ChatArtifactError.sessionNotFound) == .notFound)
        #expect(state(ChatArtifactError.unsupported) == .unsupported)
        #expect(state(ChatArtifactError.unavailable) == .unavailable)
        #expect(state(ChatArtifactError.invalidParams) == .failed(code: "invalid_params"))
        #expect(state(ChatArtifactError.unknown(code: "flux_capacitor")) == .failed(code: "flux_capacitor"))
        #expect(state(ChatArtifactError.unsupportedMedia) == .unsupportedMedia)
        #expect(state(ChatArtifactError.tooLarge(limitBytes: 9)) == .tooLarge(actualSize: nil, limit: 9))
    }

    @Test func transportCopyNamesTheSideThatIsDown() {
        // A phone that knows its own session dropped must not send the user
        // to inspect the Mac.
        let connected = ChatArtifactConnectionHint.connected.unreachableCopy
        let reconnecting = ChatArtifactConnectionHint.reconnecting.unreachableCopy
        let disconnected = ChatArtifactConnectionHint.disconnected.unreachableCopy
        #expect(connected.title != reconnecting.title)
        #expect(connected.title != disconnected.title)
        #expect(reconnecting.title != disconnected.title)
        #expect(!reconnecting.message.contains("Check the connection"))
        #expect(!disconnected.message.contains("Check the connection"))
    }

    @Test func onlyTransportErrorsClaimTheMacIsUnreachable() {
        struct DecodeFailure: Error {}
        // A reply that round-tripped but failed to decode is not a
        // connectivity problem; it must not tell the user to check the Mac.
        #expect(state(DecodeFailure()) == .failed(code: nil))
    }
}
