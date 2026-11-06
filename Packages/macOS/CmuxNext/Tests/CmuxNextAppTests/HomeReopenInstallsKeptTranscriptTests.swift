import AppKit
@testable import CmuxHomeCore
@testable import CmuxNextHome
import Foundation
@testable import MessagesLabHome
import Testing

/// A chat opened again from Home's list draws the transcript the store kept for it in the view's
/// first pass, as a pinned Chief another view holds open does, so it opens at its newest message
/// (https://github.com/manaflow-ai/cmux/issues/26397). The view's binding opened the conversation
/// only after the transcript's first pass, which then installed an empty transcript and the kept
/// page arrived later, on the path that opened Chief 2 and Chief 3 at their oldest messages.
@MainActor @Suite(.serialized) struct HomeReopenInstallsKeptTranscriptTests {
    @Test func aChatShownBeforeInstallsItsKeptTranscriptInTheFirstPass() async throws {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        store.start()
        defer { store.stop() }
        for _ in 0..<20_000 where !(store.me != nil && store.isOnline) { await Task.yield() }
        let me = try #require(store.me?.id)
        let id = ConversationID("conv_chief")
        // Shown once, then left: the store keeps its transcript.
        await store.open(id)
        #expect(!store.transcript(for: id).isEmpty, "the first page is in")
        store.close(id)
        #expect(store.transcript(for: id).isEmpty, "no window while no view shows it")

        let view = HomeNativeTranscriptView(store: store, conversation: id, me: me)
        defer { view.stop() }
        let installed = try #require(view.transcript.controller.store, "the transcript installed in its first pass")
        #expect(!installed.state.conversation.messages.isEmpty, "the first pass installed the kept transcript, not an empty one")
        #expect(installed.state.ui.scroll.pinnedToBottom, "it opens at the newest message")
    }
}
