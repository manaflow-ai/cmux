import AppKit
import CmuxNextBridge
import CmuxNextDaemon
import Foundation
import Observation
@testable import CmuxNextSidebar
import Testing

/// The document store tells its observers directly (`SidebarDocStore.observe`) that a change was
/// refused, that a change settled with no echo, or that favicons changed. The app-wide notifications
/// `cmux.sidebar.docRefused`, `cmux.sidebar.docSettled` and `cmux.sidebar.itemFaviconsChanged` are gone; a list holding
/// a drop's look lets it go on its store's event. Each list is given its store (`SidebarListView.docStore`); no test
/// writes the app-wide `SidebarDocStore.current`, so suites running beside these never see their stores.
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

    /// The favicon cache's revision, as the App's follow reads it.
    @Observable @MainActor final class Revision { var value = 0 }

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

    /// As `base::ObserverList`: observers hear an event in the order they were added.
    @Test func observersHearAnEventInTheOrderTheyWereAdded() {
        let store = SidebarDocStore(remote: nil, mirror: nil)
        var heard: [Int] = []
        let observations = (0..<8).map { index in store.observe { _ in heard.append(index) } }
        store.faviconsChanged()
        #expect(heard == Array(0..<8), "heard \(heard)")
        observations.forEach { $0.cancel() }
    }

    /// As `base::ObserverList`: an observer an earlier one cancels during an event does not hear that event.
    @Test func anObserverCancelledDuringAnEventDoesNotHearIt() {
        let store = SidebarDocStore(remote: nil, mirror: nil)
        let later = Told()
        var second: SidebarDocObservation?
        let first = store.observe { _ in second?.cancel() }
        second = store.observe { later.events.append($0) }
        store.faviconsChanged()
        #expect(later.events.isEmpty, "a cancelled observer heard the event: \(later.events)")
        first.cancel()
    }

    /// As `base::CallbackListSubscription`: an observation released without `cancel()` hears nothing more.
    @Test func aReleasedObservationHearsNothingMore() {
        let store = SidebarDocStore(remote: nil, mirror: nil)
        let told = Told()
        var observation: SidebarDocObservation? = store.observe { told.events.append($0) }
        store.faviconsChanged()
        #expect(told.count(.faviconsChanged) == 1 && observation != nil)
        observation = nil
        store.faviconsChanged()
        #expect(told.count(.faviconsChanged) == 1, "a released observation was told")
    }

    /// The App's favicon follow tells the store's observers on each favicon revision. It is a ServiceObservation
    /// (R-obs): the first pass tells in the caller's turn, a revision in the follow's visible task.
    @Test func aFaviconRevisionTellsTheStoresObservers() async {
        let store = SidebarDocStore(remote: nil, mirror: nil)
        let revision = Revision()
        let rig = MainDeadlineRig()
        let (events, observation) = Self.events(of: store)
        defer { observation.cancel() }
        let follow = SidebarDocMachines.followFavicons(store, revision: { revision.value }, byOrigin: { [:] },
                                                       faviconKey: { _ in nil }, on: rig.work)
        defer { withExtendedLifetime(follow) {} }
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == .faviconsChanged, "the follow's first pass told nothing")
        revision.value += 1
        rig.frame()
        #expect(await iterator.next() == .faviconsChanged, "a new favicon revision told nothing")
    }

    /// How often the bands follow showed its layout.
    @MainActor final class ShownCount { var value = 0 }

    /// p06-scheduler-339 fixer (rule 9, side effects while hidden): the document's bands follow is a
    /// ServiceObservation with no visibility node, so it follows the daemon while no window shows a sidebar: a new
    /// live workspace redraws the bands in one visible task after the change.
    @Test func theBandsFollowRunsWithNoWindow() {
        let store = SidebarDocStore(remote: nil, mirror: nil)
        let daemon = DaemonStore(), shown = ShownCount()
        let rig = MainDeadlineRig()
        let machines = SidebarDocMachines(stores: { [daemon] }, machine: { _ in daemon })
        let follows = machines.follow(store, connected: { false }, serves: { false }, connectedRemotes: { [] },
                                      shown: { _ in shown.value += 1 }, on: rig.work)
        defer { withExtendedLifetime(follows) {} }
        #expect(shown.value == 1, "the bands follow's first pass showed nothing")

        daemon.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [
            WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: "w1"), name: "w1", screens: []),
        ]))
        #expect(shown.value == 1, "the bands redrew inside the change")
        rig.frame()
        #expect(shown.value == 2, "a new live workspace did not redraw the bands with no window")
    }

    @Test func aListFollowsTheStoreItIsGiven() {
        let store = SidebarDocStore(remote: nil, mirror: nil)
        let (list, window) = SidebarGroupDragRailTests.list(SidebarGroupDragRailTests.Drops())
        defer { window.close() }
        #expect(list.docObservation == nil, "a list with no store observes one")
        list.docStore = store
        let observation = list.docObservation
        #expect(observation?.observed === store, "the list does not observe its store")
        list.docStore = store
        #expect(list.docObservation === observation, "giving the same store again observed it twice")
        let next = SidebarDocStore(remote: nil, mirror: nil)
        list.docStore = next
        #expect(list.docObservation?.observed === next && observation?.observed == nil, "the list kept the old store")
    }

    /// A realized link row draws the favicon that arrived after its first configure, on the store's event.
    @Test func aLinkRowDrawsItsFaviconOnTheStoresEvent() throws {
        _ = NSApplication.shared
        let address = "https://example.com/favicon.ico"
        let link = SidebarListItem(id: "itm_link", ref: .url("https://example.com"), title: "Example", iconAddress: address)
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let list = SidebarListView(model: SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: [.item(link)])]))
        let store = SidebarDocStore(remote: nil, mirror: nil)
        list.docStore = store
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 300))
        window.contentView = root
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        let previous = SidebarModel.itemFavicon
        defer { SidebarModel.itemFavicon = previous } // set and restored in this one synchronous turn
        var favicons: [String: SidebarFavicon] = [:]
        SidebarModel.itemFavicon = { favicons[$0] }
        list.reload(animated: false)
        let row = try #require(list.rowViews[.item(link.id)], "the link row is not realized")
        #expect(row.debugIcon == nil, "the row drew a favicon before one arrived")
        let context = try #require(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        favicons[address] = SidebarFavicon(try #require(context.makeImage()))
        store.faviconsChanged()
        #expect(row.debugIcon == "favicon" && row.debugIconAddress == address, "the link row did not draw the favicon that arrived")
    }

    /// A drop the store refuses inside the drop call (the document is not active): the list lets the drop's look go
    /// at once and the card flies back.
    @Test func aDropRefusedAtOnceLetsGo() throws {
        let store = SidebarDocStore(remote: nil, mirror: nil)
        let drops = SidebarGroupDragRailTests.Drops()
        let (list, window) = SidebarGroupDragRailTests.list(drops) { items, target in store.move(items, to: target, title: "Move") }
        defer { window.close() }
        list.docStore = store
        try SidebarGroupDragRailTests.dragInfraPastEmpty(list)
        #expect(drops.targets.count == 1, "the drop did not reach the store: \(drops.targets)")
        #expect(list.settling == nil, "a refused drop kept its look: \(SidebarGroupDragRailTests.describe(list))")
    }

    /// A drop the daemon refuses after a round trip: the list holds the drop's look until the store tells the refusal.
    @Test func aDropTheDaemonRefusesLetsGoOnTheStoresEvent() async throws {
        let store = try await Self.loaded(Remote { throw Refused() })
        let (events, observation) = Self.events(of: store)
        defer { observation.cancel() }
        let (list, window) = SidebarGroupDragRailTests.list(SidebarGroupDragRailTests.Drops()) { items, target in
            store.move(items, to: target, title: "Move")
        }
        defer { window.close() }
        list.docStore = store
        try SidebarGroupDragRailTests.dragInfraPastEmpty(list)
        let key = try #require(list.settling?.key, "the drop did not settle on its move: \(SidebarGroupDragRailTests.describe(list))")
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == .refused(key: key))
        #expect(list.settling == nil, "the daemon's refusal did not end the settle: \(SidebarGroupDragRailTests.describe(list))")
    }
}
