import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// A chat opening on its history draws its composer and bottom stack in place: the source's
/// news about itself that follows the history batch in the same tick (the catch-up's end, a
/// status) is not a change to the chat. It used to clear `lastChangeWasReplay`, and the
/// composer animated its collapse as if the person had done it, a 35 pt move over a dozen
/// frames (#59189, slow-history-chat).
@MainActor
@Suite struct ChatOpeningStaysReplayTests {
    private static let at = Date(timeIntervalSince1970: 1_790_000_000)

    private static func history() -> [AgentSessionEvent] {
        [.userMessage(text: "Read this", promptId: "p", turnId: "t", attachments: [], at: at),
         .update(.agentMessageChunk(text: "Done.", messageId: "m")),
         .turnResult(turnId: "t", status: .completed, errorText: nil, at: at)]
    }

    @Test func theCatchUpsEndAfterTheHistoryKeepsItTheLastChange() {
        let store = AgentChatStore(source: PromptResendTests.Recorder())
        store.nextFrame = nil
        store.apply(.historyLoading(true))
        store.apply(.batch(Self.history()))
        store.placeBottomStackInstantly = true
        store.apply(.historyLoading(false))
        store.apply(.status(.idle))
        #expect(store.lastChangeWasReplay)
        #expect(store.placeBottomStackInstantly)
    }

    @Test func aChangeToTheChatAfterTheHistoryIsNotAReplay() {
        let store = AgentChatStore(source: PromptResendTests.Recorder())
        store.nextFrame = nil
        store.apply(.batch(Self.history()))
        store.placeBottomStackInstantly = true
        store.apply(.queued(text: "next", promptId: "q", position: 0))
        #expect(!store.lastChangeWasReplay)
        #expect(!store.placeBottomStackInstantly)
    }
}
