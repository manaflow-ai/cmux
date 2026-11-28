import Testing
@testable import CmuxHomeCore

/// The store's hooks per conversation: every live registered view hears an
/// intent of its conversation once, an unregistered or freed one hears
/// nothing, and with none the store's own hook hears it.
@MainActor
@Suite struct StoreConversationHooksTests {
    let id = ConversationID("conv_aziz")
    let other = ConversationID("conv_other")

    func cursor(_ conversation: ConversationID) -> HomeIntent {
        HomeIntent(op: .setReadCursor(conversation: conversation, seq: 1))
    }

    @Test func eachLiveViewOfTheConversationHearsItOnce() {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        var heard: [String] = []
        let first = HomeConversationHooks(conversation: id, onUnanswered: { _ in heard.append("first") })
        let second = HomeConversationHooks(conversation: id, onUnanswered: { _ in heard.append("second") })
        let elsewhere = HomeConversationHooks(conversation: other, onUnanswered: { _ in heard.append("other") })
        store.register(first)
        store.register(first)
        store.register(second)
        store.register(elsewhere)
        store.reportUnanswered(cursor(id))
        #expect(heard == ["first", "second"])
        store.unregister(second)
        heard = []
        store.reportUnanswered(cursor(id))
        #expect(heard == ["first"])
        store.unregister(first)
        store.unregister(first)
        store.unregister(elsewhere)
        #expect(store.registeredHookCount == 0)
    }

    @Test func freedHooksHearNothingAndArePruned() {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        var fallback = 0
        store.onRefusal = { _, _ in fallback += 1 }
        var heard = 0
        do {
            let hooks = HomeConversationHooks(conversation: id, onRefusal: { _, _ in heard += 1 })
            store.register(hooks)
        }
        store.reportRefusal(cursor(id), .notAuthorized)
        #expect(heard == 0)
        #expect(fallback == 1)
        #expect(store.registeredHookCount == 0)
    }

    @Test func aHookThatUnregistersWhileItRunsChangesNoDeliveryOfThatIntent() {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        var heard: [String] = []
        let second = HomeConversationHooks(conversation: id, onUnanswered: { _ in heard.append("second") })
        let first = HomeConversationHooks(conversation: id)
        first.onUnanswered = { [weak store] _ in
            heard.append("first")
            store?.unregister(second)
        }
        store.register(first)
        store.register(second)
        store.reportUnanswered(cursor(id))
        #expect(heard == ["first", "second"])
        store.unregister(first)
    }
}
