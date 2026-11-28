import Testing
@testable import CmuxHomeCore
@testable import CmuxHomeRender

/// One object owns each open/close pair (round-5 review, major 2): a
/// `HomeStoreBinding` opens its conversation on the store when it starts
/// and closes exactly that open when it stops, also when it stops before
/// the first page is in. Hosts never call `HomeStore.open` themselves, so
/// a view that goes away early cannot leave the viewer count, the source's
/// subscription or an "open" inbox row behind.
@MainActor
@Suite struct BindingOpenCloseTests {
    let id = ConversationID("conv_infra")

    func started() async throws -> (HomeStore, GatedHomeSource, ParticipantID) {
        let source = GatedHomeSource(MockHomeSource(options: .immediate))
        let store = HomeStore(source: source)
        store.start()
        try await until { store.me != nil && store.isOnline }
        return (store, source, try #require(store.me?.id))
    }

    func binding(_ store: HomeStore, me: ParticipantID) -> HomeStoreBinding {
        let controller = HomeController(conversation: id, me: me, palette: Fixtures.palette, deadline: ManualDeadline())
        return HomeStoreBinding(store: store, controller: controller)
    }

    @Test func aBindingOpensItsConversationAndTwoViewsCloseItOnce() async throws {
        let (store, source, me) = try await started()
        let first = binding(store, me: me)
        let second = binding(store, me: me)
        try await until { !store.transcript(for: id).isEmpty }
        #expect(store.viewers[id] == 2)
        #expect(source.snapshots == [id], "two views of one conversation read it twice")
        first.stop()
        #expect(source.closes.isEmpty, "one view going away closed a transcript another view shows")
        #expect(!store.transcript(for: id).isEmpty)
        second.stop()
        #expect(source.closes == [id])
        #expect(store.viewers[id] == nil)
        store.stop()
    }

    /// The Mac tab closed (its view's deinit) before anything else ran.
    @Test func aBindingStoppedRightAfterItStartsClosesOnce() async throws {
        let (store, source, me) = try await started()
        let early = binding(store, me: me)
        early.stop()
        for _ in 0..<500 { await Task.yield() }
        #expect(store.viewers[id] == nil, "an open that ran after the stop was never closed")
        #expect(source.closes == [id])
        #expect(store.mirror.windows[id] == nil)
        store.stop()
    }

    /// iOS back navigation while the first page loads.
    @Test func aBindingStoppedDuringTheLoadStaysClosedAndDropsThePage() async throws {
        let (store, source, me) = try await started()
        source.hold()
        let early = binding(store, me: me)
        try await until { source.waiting == 1 }
        early.stop()
        source.release()
        for _ in 0..<500 { await Task.yield() }
        #expect(store.viewers[id] == nil)
        // The stop's close, and again once the read returned.
        #expect(source.closes == [id, id])
        #expect(store.mirror.windows[id] == nil, "the page read before the stop put the transcript back")
        store.stop()
    }

    @Test func aBindingStoppedTwiceClosesOnce() async throws {
        let (store, source, me) = try await started()
        let twice = binding(store, me: me)
        try await until { !store.transcript(for: id).isEmpty }
        twice.stop()
        twice.stop()
        #expect(source.closes == [id])
        #expect(store.viewers[id] == nil)
        // Another view still opens it afresh.
        let again = binding(store, me: me)
        try await until { !store.transcript(for: id).isEmpty }
        #expect(!store.transcript(for: id).isEmpty)
        again.stop()
        #expect(source.closes == [id, id])
        store.stop()
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<20_000 where !condition() { await Task.yield() }
        #expect(condition())
        if !condition() { throw CancellationError() }
    }
}
