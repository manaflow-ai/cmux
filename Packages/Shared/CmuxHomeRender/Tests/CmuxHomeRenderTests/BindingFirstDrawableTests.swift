import Testing
@testable import CmuxHomeCore
@testable import CmuxHomeRender

/// A fresh launch's Home showed one snapshot round trip after it had everything it draws (CMUX-571, about
/// 490 ms on a bench Mac): the Chief conversation was just made, with no messages, and Home waited for its
/// transcript read anyway. `firstDrawable()` returns at the owner's word that the conversation is empty; a
/// conversation with messages, or one only the launch cache names, still waits for its first page.
@MainActor
@Suite struct BindingFirstDrawableTests {
    func started() async throws -> (HomeStore, GatedHomeSource, ParticipantID) {
        let source = GatedHomeSource(MockHomeSource(options: .immediate))
        let store = HomeStore(source: source)
        store.start()
        try await until { store.me != nil && store.isOnline }
        return (store, source, try #require(store.me?.id))
    }

    func binding(_ store: HomeStore, _ id: ConversationID, me: ParticipantID) -> HomeStoreBinding {
        let controller = HomeController(conversation: id, me: me, palette: Fixtures.palette, deadline: ManualDeadline())
        return HomeStoreBinding(store: store, controller: controller)
    }

    @Test func anEmptyConversationTheOwnerNamedDrawsBeforeItsRead() async throws {
        let (store, source, me) = try await started()
        let made = try await store.perform(.createGroup(title: "Fresh", participants: []))
        let id = try #require(made.conversation)
        try await until { store.confirmed.contains(id) && store.summary(id)?.lastSeq == 0 }
        source.hold()
        let view = binding(store, id, me: me)
        try await until { source.waiting == 1 }
        let drawn = Flag()
        Task { await view.firstDrawable(); drawn.on = true }
        try await until { drawn.on }
        #expect(drawn.on, "an empty conversation's first draw waited for a read with nothing to bring")
        source.release()
        view.stop()
        store.stop()
    }

    @Test func aConversationWithMessagesWaitsForItsFirstPage() async throws {
        let (store, source, me) = try await started()
        let id = ConversationID("conv_infra")
        source.hold()
        let view = binding(store, id, me: me)
        try await until { source.waiting == 1 }
        let drawn = Flag()
        Task { await view.firstDrawable(); drawn.on = true }
        for _ in 0..<2_000 { await Task.yield() }
        #expect(!drawn.on, "a conversation with history drew before its first page was in")
        source.release()
        try await until { drawn.on }
        view.stop()
        store.stop()
    }

    @MainActor final class Flag { var on = false }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<20_000 where !condition() { await Task.yield() }
        #expect(condition())
        if !condition() { throw CancellationError() }
    }
}
