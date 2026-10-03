import CmuxHomeCore
import CoreGraphics
import Foundation
import Testing
@testable import CmuxHomeRender

/// The renderer on CmuxHomeCore's mock owner and its seed data.
@MainActor
@Suite struct MockSeedTests {
    @Test func rendersEverySeedConversation() async throws {
        let source = MockHomeSource(options: .immediate)
        let inbox = try await source.inbox()
        let me = inbox.me.id
        for summary in inbox.conversations {
            let page = try await source.snapshot(of: summary.id, tail: 60)
            let c = HomeController(conversation: summary.id, me: me)
            c.resize(to: CGSize(width: 628, height: 1041))
            let items = TranscriptWindow(messages: page.messages).items(pending: [], me: me)
            c.update(items: items, summary: page.conversation, typing: [], hasOlder: false)
            let parts = c.scene.model.rows.filter { $0.spec.partRow != nil }
            #expect(parts.count == page.messages.count, "\(summary.id)")
            #expect(c.isPinnedToNewest)
            let labels = Set(c.accessibilityItems().map(\.label))
            if let last = page.messages.last { #expect(labels.contains(last.plainText), "\(summary.id)") }
        }
    }

    /// The binding feeds store state to the controller and sends its intents
    /// through `HomeStore.perform`; the owner's echo keeps the same row key.
    @Test func bindingRoundTripsASend() async throws {
        let source = MockHomeSource(options: .immediate)
        let store = HomeStore(source: source)
        store.start()
        let id = ConversationID("conv_infra")
        try await until { store.me != nil && store.isOnline }
        await store.open(id)
        let me = try #require(store.me?.id)
        let controller = HomeController(conversation: id, me: me)
        controller.resize(to: CGSize(width: 628, height: 1041))
        let binding = HomeStoreBinding(store: store, controller: controller)
        defer { binding.stop() }
        #expect(controller.items.count == store.transcript(for: id).count)
        controller.handle(.insertText("Ping from the render core", replacing: nil))
        let intent = try #require(controller.handle(.send))
        try await until { store.transcript(for: id).contains { $0.key == intent.key && $0.delivery == .committed } }
        try await until { controller.items.contains { $0.key == intent.key && $0.delivery == .committed } }
        #expect(controller.scene.model.index["part:\(intent.key.rawValue):0"] != nil)
        store.stop()
    }

    /// Yields until `condition` holds (tests only; bounded).
    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<20_000 where !condition() { await Task.yield() }
        #expect(condition())
        if !condition() { throw CancellationError() }
    }
}
