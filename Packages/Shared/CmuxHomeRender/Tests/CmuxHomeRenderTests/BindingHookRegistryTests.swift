import Testing
@testable import CmuxHomeCore
@testable import CmuxHomeRender

/// Refusals and unanswered ops nobody awaits reach every live view of their
/// conversation, once each (lane 16 review, major): two Mac tabs of one
/// conversation, or a screen opened again while an older one lives. A view
/// that stopped, or was freed without stopping, hears nothing and leaves
/// nothing behind in the store; with no live view the store's own hook
/// hears it.
@MainActor
@Suite struct BindingHookRegistryTests {
    let id = ConversationID("conv_infra")

    func started() async throws -> (HomeStore, ParticipantID) {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        store.start()
        for _ in 0..<20_000 where store.me == nil || !store.isOnline { await Task.yield() }
        return (store, try #require(store.me?.id))
    }

    func binding(_ store: HomeStore, me: ParticipantID) -> HomeStoreBinding {
        let controller = HomeController(conversation: id, me: me, palette: Fixtures.palette, deadline: ManualDeadline())
        return HomeStoreBinding(store: store, controller: controller)
    }

    func reaction() -> HomeIntent {
        HomeIntent(op: .addReaction(message: MessageID("m_1"), conversation: id, reaction: .tapback(.love), partIndex: 0))
    }

    @Test func stoppingOneOfTwoViewsLeavesTheOtherHearingEachOnce() async throws {
        let (store, me) = try await started()
        let first = binding(store, me: me)
        let second = binding(store, me: me)
        var firstRefused: [IdempotencyKey] = [], firstUnanswered: [IdempotencyKey] = []
        var secondHeard = 0
        first.onRefusal = { intent, _ in firstRefused.append(intent.key) }
        first.onUnanswered = { firstUnanswered.append($0.key) }
        second.onRefusal = { _, _ in secondHeard += 1 }
        second.onUnanswered = { _ in secondHeard += 1 }
        second.stop()
        let refused = reaction(), unanswered = reaction()
        store.reportRefusal(refused, .notAuthorized)
        store.reportUnanswered(unanswered)
        #expect(firstRefused == [refused.key], "the stopped view swallowed the refusal")
        #expect(firstUnanswered == [unanswered.key], "the stopped view swallowed the unanswered op")
        #expect(secondHeard == 0, "a stopped view heard an intent")
        first.stop()
        store.stop()
    }

    @Test func twoLiveViewsEachHearItOnce() async throws {
        let (store, me) = try await started()
        let first = binding(store, me: me)
        let second = binding(store, me: me)
        var heard: [String] = []
        first.onUnanswered = { _ in heard.append("first") }
        second.onUnanswered = { _ in heard.append("second") }
        store.reportUnanswered(reaction())
        #expect(heard == ["first", "second"], "live views heard it out of registration order")
        first.stop()
        second.stop()
        store.stop()
    }

    /// One of two views freed without `stop()`: its hook leaves the store
    /// at once, and the other view hears each intent exactly once.
    @Test func freeingOneOfTwoViewsLeavesTheOtherHearingEachOnce() async throws {
        let (store, me) = try await started()
        let kept = binding(store, me: me)
        var keptRefused: [IdempotencyKey] = [], keptUnanswered: [IdempotencyKey] = []
        kept.onRefusal = { intent, _ in keptRefused.append(intent.key) }
        kept.onUnanswered = { keptUnanswered.append($0.key) }
        var heardByFreed = 0
        weak var freed: HomeStoreBinding?
        do {
            let view = binding(store, me: me)
            view.onRefusal = { _, _ in heardByFreed += 1 }
            view.onUnanswered = { _ in heardByFreed += 1 }
            freed = view
            await view.opened()
        }
        #expect(freed == nil, "the binding outlived its host")
        #expect(store.registeredHookCount == 1, "a freed view left its hook in the store")
        let refused = reaction(), unanswered = reaction()
        store.reportRefusal(refused, .notAuthorized)
        store.reportUnanswered(unanswered)
        #expect(keptRefused == [refused.key])
        #expect(keptUnanswered == [unanswered.key])
        #expect(heardByFreed == 0, "a freed view heard an intent")
        kept.stop()
        #expect(store.registeredHookCount == 0)
        store.stop()
    }

    /// A view stopped by another view's handler while an intent is being
    /// delivered does not hear that intent.
    @Test func aViewStoppedDuringADeliveryDoesNotHearIt() async throws {
        let (store, me) = try await started()
        let first = binding(store, me: me)
        let second = binding(store, me: me)
        var firstHeard = 0, secondHeard = 0
        first.onRefusal = { _, _ in firstHeard += 1; second.stop() }
        first.onUnanswered = { _ in firstHeard += 1; second.stop() }
        second.onRefusal = { _, _ in secondHeard += 1 }
        second.onUnanswered = { _ in secondHeard += 1 }
        store.reportRefusal(reaction(), .notAuthorized)
        store.reportUnanswered(reaction())
        #expect(firstHeard == 2, "the live view did not hear each intent exactly once")
        #expect(secondHeard == 0, "a view stopped during a delivery heard that intent")
        first.stop()
        #expect(store.registeredHookCount == 0)
        store.stop()
    }

    /// A view opened by a handler while an intent is being delivered misses
    /// that intent and hears the next one.
    @Test func aViewOpenedDuringADeliveryHearsOnlyTheNextIntent() async throws {
        let (store, me) = try await started()
        let first = binding(store, me: me)
        var late: HomeStoreBinding?
        var lateHeard: [IdempotencyKey] = []
        var firstHeard: [IdempotencyKey] = []
        first.onUnanswered = { intent in
            firstHeard.append(intent.key)
            guard late == nil else { return }
            let view = binding(store, me: me)
            view.onUnanswered = { lateHeard.append($0.key) }
            late = view
        }
        let inFlight = reaction(), next = reaction()
        store.reportUnanswered(inFlight)
        #expect(late != nil)
        #expect(lateHeard.isEmpty, "a view opened during a delivery heard the in-flight intent")
        store.reportUnanswered(next)
        #expect(firstHeard == [inFlight.key, next.key])
        #expect(lateHeard == [next.key], "a view opened during a delivery missed the next intent")
        first.stop()
        late?.stop()
        #expect(store.registeredHookCount == 0)
        store.stop()
    }

    @Test func withNoLiveViewTheStoresOwnHookHearsIt() async throws {
        let (store, me) = try await started()
        var fallback: [IdempotencyKey] = []
        store.onRefusal = { intent, _ in fallback.append(intent.key) }
        let view = binding(store, me: me)
        var viewHeard = 0
        view.onRefusal = { _, _ in viewHeard += 1 }
        view.stop()
        let intent = reaction()
        store.reportRefusal(intent, .notAuthorized)
        #expect(viewHeard == 0)
        #expect(fallback == [intent.key], "a refusal for a conversation no view shows was dropped")
        store.stop()
    }

    @Test func manyViewsOpenedAndStoppedLeaveNoHookBehind() async throws {
        let (store, me) = try await started()
        for _ in 0..<200 { binding(store, me: me).stop() }
        #expect(store.registeredHookCount == 0, "the store keeps \(store.registeredHookCount) hooks of stopped views")
        let live = binding(store, me: me)
        var heard = 0
        live.onRefusal = { _, _ in heard += 1 }
        store.reportRefusal(reaction(), .notAuthorized)
        #expect(heard == 1)
        live.stop()
        #expect(store.registeredHookCount == 0)
        store.stop()
    }

    /// A host freed its view without `stop()`: the binding's own deinit
    /// closes the conversation and leaves no hook, and nothing reaches the
    /// freed host.
    @Test func aViewFreedWithoutStoppingLeavesNoHookAndClosesItsConversation() async throws {
        let (store, me) = try await started()
        var fallback = 0
        store.onUnanswered = { _ in fallback += 1 }
        var heardByFreed = 0
        weak var freed: HomeStoreBinding?
        do {
            let view = binding(store, me: me)
            view.onUnanswered = { _ in heardByFreed += 1 }
            freed = view
            await view.opened()
        }
        #expect(freed == nil, "the binding outlived its host")
        for _ in 0..<500 where store.registeredHookCount > 0 || store.viewers[id] != nil { await Task.yield() }
        // Before any delivery: a delivery prunes freed entries itself.
        #expect(store.registeredHookCount == 0, "a freed view left its hook in the store")
        #expect(store.viewers[id] == nil, "a freed view left its conversation open")
        store.reportUnanswered(reaction())
        #expect(heardByFreed == 0, "a freed host heard an intent")
        #expect(fallback == 1)
        store.stop()
    }
}
