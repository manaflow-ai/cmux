import AppKit
import Foundation
@testable import CmuxNextSidebar
import Testing

/// p06-scheduler-045: the document store tells its observers directly (`SidebarDocStore.observe`) that a change was
/// refused, that a change settled with no echo, or that favicons changed. The app-wide notifications
/// `cmux.sidebar.docRefused`, `cmux.sidebar.docSettled` and `cmux.sidebar.itemFaviconsChanged` are gone; a list holding
/// a drop's look lets it go on its store's event.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct SidebarDocEventsTests {
    struct Refused: Error {}

    /// What observers were told, read after the store's synchronous calls.
    @MainActor final class Told {
        var events: [SidebarDocEvent] = []
        func count(_ event: SidebarDocEvent) -> Int { events.filter { $0 == event }.count }
    }

    /// A daemon whose every change answers `reply` (a throw is the daemon's refusal).
    @MainActor final class Remote: SidebarDocRemote {
        let reply: @MainActor () throws -> SidebarDocReply
        init(reply: @escaping @MainActor () throws -> SidebarDocReply) { self.reply = reply }
        var isAvailable: Bool { true }
        func get() async throws -> Data { SidebarGroupDragRailTests.document }
        func move(_ items: [String], to target: SidebarDocTarget, key: String) async throws -> SidebarDocReply { try reply() }
        func pin(_ items: [String], key: String) async throws -> SidebarDocReply { try reply() }
        func unpin(_ items: [String], key: String) async throws -> SidebarDocReply { try reply() }
        func adopt(_ refs: [SidebarDocWorkspaceRef], key: String) async throws -> SidebarDocReply { try reply() }
        func apply(ops: Data, key: String) async throws -> SidebarDocReply { try reply() }
    }

    /// The move the rail tests drop: Infra after the empty group.
    static let target = SidebarDocTarget(section: SidebarGroupDragRailTests.section, after: "g_g-empty")
    static let infra = "g_g-infra"

    /// The events `store` tells, as a stream the test awaits.
    static func events(of store: SidebarDocStore) -> (AsyncStream<SidebarDocEvent>, SidebarDocObservation) {
        let (stream, continuation) = AsyncStream<SidebarDocEvent>.makeStream()
        let observation = store.observe { continuation.yield($0) }
        return (stream, observation)
    }

    static func loaded(_ remote: Remote) async throws -> SidebarDocStore {
        let store = SidebarDocStore(remote: remote)
        store.refresh()
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { store.isActive }
        try #require(store.isActive, "the store did not load the document")
        return store
    }

    @Test func aChangeRefusedAtOnceTellsItsKeyInTheSameTurn() {
        let store = SidebarDocStore(remote: nil, mirror: nil)
        let told = Told()
        let observation = store.observe { told.events.append($0) }
        defer { observation.cancel() }
        store.move([Self.infra], to: Self.target, title: "Move")
        let key = store.lastIntentKey
        #expect(key != nil, "the move recorded no key")
        #expect(told.events == [.refused(key: key ?? "")], "told: \(told.events)")
    }

    @Test func theDaemonsRefusalTellsTheChangesKey() async throws {
        let store = try await Self.loaded(Remote { throw Refused() })
        let (events, observation) = Self.events(of: store)
        defer { observation.cancel() }
        store.move([Self.infra], to: Self.target, title: "Move")
        let key = try #require(store.lastIntentKey)
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == .refused(key: key))
    }

    @Test func aChangeThatChangesNothingTellsItSettled() async throws {
        let store = try await Self.loaded(Remote { SidebarDocReply(revision: nil, inverse: Data("[]".utf8)) })
        let (events, observation) = Self.events(of: store)
        defer { observation.cancel() }
        store.move([Self.infra], to: Self.target, title: "Move")
        let key = try #require(store.lastIntentKey)
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == .settled(key: key))
    }

    @Test func faviconsReachEachObserverUntilItCancels() {
        let store = SidebarDocStore(remote: nil, mirror: nil)
        let first = Told(), second = Told()
        let a = store.observe { first.events.append($0) }
        let b = store.observe { second.events.append($0) }
        store.faviconsChanged()
        #expect(first.count(.faviconsChanged) == 1 && second.count(.faviconsChanged) == 1)
        a.cancel()
        #expect(a.observed == nil, "a cancelled observation still names its store")
        store.faviconsChanged()
        #expect(first.count(.faviconsChanged) == 1, "a cancelled observer was told")
        #expect(second.count(.faviconsChanged) == 2, "an observer missed the second change")
        b.cancel()
    }

    @Test func aListFollowsTheCurrentStoreOnce() {
        let store = SidebarDocStore(remote: nil, mirror: nil)
        let previous = SidebarDocStore.current
        SidebarDocStore.current = store
        defer { SidebarDocStore.current = previous }
        let (list, window) = SidebarGroupDragRailTests.list(SidebarGroupDragRailTests.Drops())
        defer { window.close() }
        let observation = list.docObservation
        #expect(observation?.observed === store, "the list does not observe the current store")
        list.followDocStore()
        #expect(list.docObservation === observation, "following the same store again observed it twice")
        let next = SidebarDocStore(remote: nil, mirror: nil)
        list.followDocStore(next)
        #expect(list.docObservation?.observed === next && observation?.observed == nil, "the list kept the old store")
    }

    /// A drop the store refuses inside the drop call (the document is not active): the list lets the drop's look go
    /// at once and the card flies back.
    @Test func aDropRefusedAtOnceLetsGo() throws {
        let store = SidebarDocStore(remote: nil, mirror: nil)
        let previous = SidebarDocStore.current
        SidebarDocStore.current = store
        defer { SidebarDocStore.current = previous }
        let drops = SidebarGroupDragRailTests.Drops()
        let (list, window) = SidebarGroupDragRailTests.list(drops) { items, target in store.move(items, to: target, title: "Move") }
        defer { window.close() }
        try SidebarGroupDragRailTests.dragInfraPastEmpty(list)
        #expect(drops.targets.count == 1, "the drop did not reach the store: \(drops.targets)")
        #expect(list.settling == nil, "a refused drop kept its look: \(SidebarGroupDragRailTests.describe(list))")
    }

    /// A drop the daemon refuses after a round trip: the list holds the drop's look until the store tells the refusal.
    @Test func aDropTheDaemonRefusesLetsGoOnTheStoresEvent() async throws {
        let store = try await Self.loaded(Remote { throw Refused() })
        let previous = SidebarDocStore.current
        SidebarDocStore.current = store
        defer { SidebarDocStore.current = previous }
        let (events, observation) = Self.events(of: store)
        defer { observation.cancel() }
        let (list, window) = SidebarGroupDragRailTests.list(SidebarGroupDragRailTests.Drops()) { items, target in
            store.move(items, to: target, title: "Move")
        }
        defer { window.close() }
        try SidebarGroupDragRailTests.dragInfraPastEmpty(list)
        let key = try #require(list.settling?.key, "the drop did not settle on its move: \(SidebarGroupDragRailTests.describe(list))")
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == .refused(key: key))
        #expect(list.settling == nil, "the daemon's refusal did not end the settle: \(SidebarGroupDragRailTests.describe(list))")
    }
}
