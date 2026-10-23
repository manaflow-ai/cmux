@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// The content cache's gone-tab watch (``GoneTabWatch``) wakes on the live tree's tab list
/// revision and asks the store's index per followed tab (d0fa911d2e5, perf-lead issue 11); it used
/// to build a set of every tab per tree change. The release rule stays: a followed tab goes once
/// its live tree listed it and lists it no more; one the tree has not listed yet (a provisional
/// key, a creation that just answered) is kept through the same change.
///
/// This guards the release rule only: it also passes on the old set-of-every-tab code. The guard
/// of the work d0fa911d2e5 removed (here and in `AgentTabStore.releaseGoneTabs`) is the STRESS
/// create bench (`instant-new-surfaces-bench.py --sessions light,stress`, key_ms p95).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct GoneTabWatchReleaseTests {
    private final class Released {
        var keys: [String] = []
        var waiter: CheckedContinuation<Void, Never>?
        func note(_ key: String) {
            keys.append(key)
            waiter?.resume()
            waiter = nil
        }
        /// Returns once a release came (at once when one already did).
        func next() async {
            guard keys.isEmpty else { return }
            await withCheckedContinuation { waiter = $0 }
        }
    }

    private static func tree(_ surfaces: [SurfaceID]) -> DaemonTree {
        let pane = PaneSnapshot(id: 1, tabs: surfaces.map { TabSnapshot(surface: $0) })
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [
            ScreenSnapshot(id: 1, active: true, activePane: 1, layout: .leaf(1), panes: [pane]),
        ])])
    }

    private static func liveStore(_ surfaces: [SurfaceID]) throws -> DaemonStore {
        let store = DaemonStore()
        let json = #"{"app":"cmux-tui","protocol":1,"session":"gone-tab-watch","generation":"g1"}"#
        store.connectionState = .connected(try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8)))
        store.apply(snapshot: tree(surfaces))
        return store
    }

    @Test func aListedTabGoesWhenTheTreeDropsItAndAnUnlistedOneStays() async throws {
        let store = try Self.liveStore([1, 2])
        let ids = store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).map(\.id)
        try #require(ids.count == 2)
        let closing = ids[1]
        let notListedYet = "provisional-tab-\(UUID().uuidString)"
        let watch = GoneTabWatch()
        let released = Released()
        for key in [ids[0], closing, notListedYet] { watch.track(key, in: store) { released.note($0) } }

        // The tree drops the second tab; the same pass sees the not-yet-listed key and keeps it.
        store.apply(snapshot: Self.tree([1]))
        await released.next()

        #expect(released.keys == [closing])
        #expect(watch.tracks(ids[0]))
        #expect(watch.tracks(notListedYet), "a tab the tree has not listed yet was let go")
    }
}
