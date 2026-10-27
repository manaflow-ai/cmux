import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation
import Testing

/// The closed-history followers of file group 305 (p06-scheduler.md, R-obs and R-index): `ClosedTabsFeed` and
/// `CloseUndoToasts` follow one closed list revision per machine (`SessionStateStore.closedRevision`) through
/// `ServiceObservation`s, not an `ObservationStream` over every machine's closed item ids. A change that is not
/// the closed list wakes neither, and a closed record still reaches the toasts while no window shows anything
/// (side effects run while hidden, rule 3).
@MainActor @Suite(.serialized)
struct ClosedHistoryObservationTests {
    private static func closed(_ id: String, at ms: UInt64) -> ClosedItem {
        let tab = ClosedItem.Tab(kind: "browser", url: "https://example.com/\(id)", empty: false)
        return ClosedItem(id: id, kind: .tab, workspaceID: ResourceID("ws_closed"), closedAtMs: ms, screens: [.init(tabs: [tab])])
    }

    /// A daemon handshake that serves the state resources (closed history).
    private static func identity() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"closed-observation-test","generation":"g1","capabilities":["\#(DaemonCapability.stateResources.rawValue)"]}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// Headless services (no window) whose daemon store serves closed history and is loaded (the feed follows
    /// only a connected, loaded store), with `closed` mirrored, and the feed.
    private static func services(closed: [ClosedItem]) throws -> (AppServices, ClosedTabsFeed) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.apply(.connected(try identity(), generationChanged: false))
        store.apply(snapshot: DaemonTree(workspaces: []))
        var mirror = SessionStateMirror()
        mirror.closed = closed
        store.session.apply(.snapshot(mirror), in: store)
        let feed = ClosedTabsFeed(services: services)
        services.closedTabs = feed
        return (services, feed)
    }

    /// Waits up to five seconds for `done`, running the posted main work in between (test-only).
    private static func wait(until done: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !done(), ContinuousClock.now < deadline {
            await drainMainTurns(rounds: 1)
            try? await Task.sleep(for: .milliseconds(20))
        }
        return done()
    }

    @Test func theClosedRevisionMovesOnlyWithTheClosedList() throws {
        let (services, _) = try Self.services(closed: [Self.closed("closed_1", at: 1)])
        let store = services.daemon.store
        let start = store.session.closedRevision

        var same = SessionStateMirror()
        same.closed = [Self.closed("closed_1", at: 1)]
        store.session.apply(.snapshot(same), in: store)
        #expect(store.session.closedRevision == start, "an equal closed list moved the revision")

        store.session.apply(.delta([.closed(Self.closed("closed_2", at: 2))]), in: store)
        #expect(store.session.closedRevision == start &+ 1)
        store.session.apply(.delta([.closedRemoved("closed_1")]), in: store)
        #expect(store.session.closedRevision == start &+ 2)
    }

    @Test func aChangeOutsideTheClosedListWakesNeitherFollower() async throws {
        let (services, feed) = try Self.services(closed: [Self.closed("closed_1", at: 1)])
        let store = services.daemon.store
        #expect(store.isLoaded)
        await drainMainTurns()
        let changes = feed.changes.revision, applies = feed.undoToasts.closedListApplies

        store.session.apply(.delta([.stash("stash_1")]), in: store)
        await drainMainTurns()

        #expect(feed.changes.revision == changes, "a stash change bumped the closed tabs feed")
        #expect(feed.undoToasts.closedListApplies == applies, "a stash change woke the undo toasts")

        // Both follow the closed list: a closed record wakes each, so the checks above are not vacuous.
        store.session.apply(.delta([.closed(Self.closed("closed_2", at: 2))]), in: store)
        #expect(await Self.wait { feed.changes.revision != changes && feed.undoToasts.closedListApplies == applies + 1 },
                "a closed record did not wake both followers once")
    }

    @Test func aClosedRecordReachesTheFollowersWhileNoWindowShows() async throws {
        let (services, feed) = try Self.services(closed: [])
        let store = services.daemon.store
        #expect(services.windows.controllers.isEmpty)
        await drainMainTurns()
        let changes = feed.changes.revision

        store.session.apply(.delta([.closed(Self.closed("closed_hidden", at: 3))]), in: store)

        #expect(await Self.wait { feed.undoToasts.recentDaemonItems.contains { $0.id == "closed_hidden" } },
                "the undo toasts never read the new closed record")
        #expect(await Self.wait { feed.changes.revision != changes }, "the closed tabs feed never signalled the change")
    }
}
