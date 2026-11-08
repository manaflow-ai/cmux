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

    @Test func everyArtifactErrorMapsToTypedFailure() {
        #expect(state(ChatArtifactError.fileNotFound) == .failure(error: .fileNotFound, actualSize: nil))
        #expect(state(ChatArtifactError.forbidden) == .failure(error: .forbidden, actualSize: nil))
        #expect(state(ChatArtifactError.macUnreachable) == .failure(error: .macUnreachable, actualSize: nil))
        #expect(state(ChatArtifactError.sessionNotFound) == .failure(error: .sessionNotFound, actualSize: nil))
        #expect(state(ChatArtifactError.unsupported) == .failure(error: .unsupported, actualSize: nil))
        #expect(state(ChatArtifactError.unavailable) == .failure(error: .unavailable, actualSize: nil))
        #expect(state(ChatArtifactError.invalidParams) == .failure(error: .invalidParams, actualSize: nil))
        #expect(state(ChatArtifactError.unsupportedMedia) == .failure(error: .unsupportedMedia, actualSize: nil))
        #expect(state(ChatArtifactError.tooLarge(limitBytes: 9)) == .failure(error: .tooLarge(limitBytes: 9), actualSize: nil))
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
        #expect(state(DecodeFailure()) == .failure(error: .loadFailed, actualSize: nil))
    }
}
