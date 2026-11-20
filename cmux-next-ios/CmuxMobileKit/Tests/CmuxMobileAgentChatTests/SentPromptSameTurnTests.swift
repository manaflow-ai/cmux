#if os(iOS)
import Foundation
import Testing
import UIKit
@testable import CmuxMobileAgentChat

/// The sent bubble is in the transcript before Send returns, so it is drawn in the frame the
/// composer clears in. Before, the list rebuilt in a later main-queue turn (its observation's
/// `Task`), 3 to 4 frames after the field emptied, behind the keyboard's resign.
@MainActor
@Suite struct SentPromptSameTurnTests {
    @Test func theSentBubbleIsInTheListBeforeSendReturns() throws {
        let source = SentPromptShownTests.Recorder()
        let store = AgentChatStore(source: source)
        let list = ChatTranscriptList(store: store, surface: AgentChatSurface())
        list.collectionView.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        list.boundsMayHaveChanged()
        list.collectionView.layoutIfNeeded()
        let before = list.layout.items.map(\.id)

        store.send(prompt: "run the tests")
        let id = try SentPromptShownTests.promptID(source)
        let ids = list.layout.items.map(\.id)
        #expect(ids.contains("u-\(AgentChatStore.localTurnKey(id))"), "shown in the same turn as Send: \(before) → \(ids)")
    }

    @Test func aHeldTranscriptWaitsForItsRelease() throws {
        let source = SentPromptShownTests.Recorder()
        let store = AgentChatStore(source: source)
        let surface = AgentChatSurface()
        let list = ChatTranscriptList(store: store, surface: surface)
        list.collectionView.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        list.boundsMayHaveChanged()
        surface.holdsTranscript = true
        store.send(prompt: "run the tests")
        let id = try SentPromptShownTests.promptID(source)
        #expect(!list.layout.items.map(\.id).contains("u-\(AgentChatStore.localTurnKey(id))"), "a card on the tab grid does not rebuild per change")
    }
}
#endif
