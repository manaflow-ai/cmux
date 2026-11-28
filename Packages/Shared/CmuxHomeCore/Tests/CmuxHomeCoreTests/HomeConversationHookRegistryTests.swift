import Testing
@testable import CmuxHomeCore

/// The hook registry on its own: one entry per hooks object, live hooks in
/// registration order, freed hooks pruned, and other conversations untouched.
@MainActor
@Suite struct HomeConversationHookRegistryTests {
    let id = ConversationID("conv_aziz")
    let other = ConversationID("conv_other")

    func cursor(_ conversation: ConversationID) -> HomeIntent {
        HomeIntent(op: .setReadCursor(conversation: conversation, seq: 1))
    }

    @Test func registersOnceAndReturnsLiveHooksInOrder() {
        var registry = HomeConversationHookRegistry()
        let first = HomeConversationHooks(conversation: id)
        let second = HomeConversationHooks(conversation: id)
        let elsewhere = HomeConversationHooks(conversation: other)
        registry.register(first)
        registry.register(first)
        registry.register(second)
        registry.register(elsewhere)
        #expect(registry.count == 3)
        #expect(registry.liveHooks(for: cursor(id)).map(ObjectIdentifier.init) == [first, second].map(ObjectIdentifier.init))
        registry.unregister(first)
        #expect(registry.liveHooks(for: cursor(id)).map(ObjectIdentifier.init) == [ObjectIdentifier(second)])
        #expect(registry.liveHooks(for: cursor(other)).map(ObjectIdentifier.init) == [ObjectIdentifier(elsewhere)])
    }

    @Test func freedHooksArePrunedWhenRead() {
        var registry = HomeConversationHookRegistry()
        do {
            let hooks = HomeConversationHooks(conversation: id)
            registry.register(hooks)
        }
        #expect(registry.count == 1)
        #expect(registry.liveHooks(for: cursor(id)).isEmpty)
        #expect(registry.count == 0)
    }
}
