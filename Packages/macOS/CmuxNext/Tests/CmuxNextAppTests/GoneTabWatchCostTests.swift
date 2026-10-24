@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// A real store seen through the watch's only seam (``LiveTabListing``), counting what the watch
/// asks of it. The watch cannot reach the tree another way, so these counts are its whole cost per
/// tree change; the code under test cannot leave work out of them.
@MainActor
private final class CountingLiveTabs: LiveTabListing {
    let store: DaemonStore
    /// Tab lookups the watch made (``liveTreeLists(tab:)``).
    private(set) var lookups = 0
    /// Each lookup's tab id as it happens: the test waits on these, never on time.
    let looked: AsyncStream<String>
    private let sink: AsyncStream<String>.Continuation

    init(_ store: DaemonStore) {
        self.store = store
        (looked, sink) = AsyncStream<String>.makeStream()
    }

    var liveTabListRevision: UInt64? { store.liveTabListRevision }

    func liveTreeLists(tab id: String) -> Bool? {
        lookups += 1
        sink.yield(id)
        return store.liveTreeLists(tab: id)
    }
}

/// A tab-list change costs the gone-tab watch the tabs it tracks, not the session (CLAUDE.md "Go
/// past Chrome where cmux is scripted": a script that adds tabs, moves panes or makes columns in
/// 50 background workspaces must not make every watcher walk every tab of every workspace), and
/// the watch still releases a tracked tab the tree drops.
@MainActor @Suite(.timeLimit(.minutes(1))) struct GoneTabWatchCostTests {
    /// `count` workspaces of one pane with `tabs` tabs. `grown`: workspace 0 gets one more tab.
    /// `dropped`: workspace 1 loses its first tab.
    private static func session(_ count: Int, tabs: Int = 3, grown: Bool = false, dropped: Bool = false) -> DaemonTree {
        DaemonTree(workspaces: (0..<count).map { index in
            let base = UInt64(index * 100)
            let extra = grown && index == 0 ? 1 : 0
            let first = dropped && index == 1 ? 1 : 0
            let pane = PaneSnapshot(id: PaneID(rawValue: base + 1),
                                    tabs: (first..<(tabs + extra)).map { TabSnapshot(surface: SurfaceID(rawValue: base + 10 + UInt64($0)), title: "~") })
            let screen = ScreenSnapshot(id: ScreenID(rawValue: base + 2), layout: .leaf(pane.id), panes: [pane])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: base + 3), key: nil, name: "w\(index)", screens: [screen])
        })
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"gone-tab-cost-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    @Test(arguments: [50, 500])
    func aTabListChangeLooksUpOnlyTheTrackedTabs(sessionSize: Int) async throws {
        let store = DaemonStore()
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.session(sessionSize))
        let tracked = [try #require(store.tab(surface: SurfaceID(rawValue: 10))).id,
                       try #require(store.tab(surface: SurfaceID(rawValue: 110))).id]
        let listing = CountingLiveTabs(store)
        var lookups = listing.looked.makeAsyncIterator()
        let watch = GoneTabWatch()
        let (released, releasing) = AsyncStream<String>.makeStream()
        var releases = released.makeAsyncIterator()
        var releasedSoFar: [String] = []
        for key in tracked {
            watch.track(key, in: listing) { key in
                releasedSoFar.append(key)
                releasing.yield(key)
            }
        }
        // `track` looks each tab up once, then the watch's first pass looks both up.
        for _ in 0..<(2 * tracked.count) { _ = await lookups.next() }
        let start = listing.lookups

        // Workspace 0 gets a tab: the tab list changed, both tracked tabs stay.
        store.apply(snapshot: Self.session(sessionSize, grown: true))
        for _ in tracked { _ = await lookups.next() }
        #expect(listing.lookups - start == tracked.count,
                "one tab-list change made \(listing.lookups - start) lookups in a \(sessionSize)-workspace session to watch \(tracked.count) tabs")
        #expect(releasedSoFar.isEmpty, "a tab the tree still lists was released")

        // Workspace 1 drops the second tracked tab: the watch releases it, and only it, after one
        // more pass over its tracked tabs (so the change before woke it exactly once).
        store.apply(snapshot: Self.session(sessionSize, grown: true, dropped: true))
        let gone = await releases.next()
        #expect(gone == tracked[1])
        #expect(releasedSoFar == [tracked[1]])
        #expect(listing.lookups - start == 2 * tracked.count, "\(listing.lookups - start) lookups over two tab-list changes")
        watch.forget(tracked[0])
        watch.forget(tracked[1])
    }
}
