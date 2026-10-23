@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Observation
import os
import Testing

/// No O(all) work per event (perf-lead.md cause 6). Three owners keep state per tab or pane and
/// let it go when the daemon tree drops it: the terminal and page cache (`GoneTabWatch`), the
/// agent pages (`AgentTabStore`) and the internal page tabs (`InternalPageTabStore`). Each one
/// built the set of every tab id (and every pane id) of the tree to answer "is this tab still
/// listed": every workspace's screens, every screen's panes and every pane's tab list read and
/// tracked, on each tab added, closed or moved anywhere, and on each pane teardown. In the STRESS
/// session that is thousands of tracked reads, three times, per Cmd-T or Cmd-W.
///
/// The guard: what these owners read to answer is their own tabs and panes, not the tree. A pane
/// in another workspace that reorders its tabs or its workspace's screens must not reach them.
/// Their dependencies are the observable footprint of the work: a tracked read of every pane
/// becomes a wakeup on every pane's change.
@MainActor
struct LiveTreeWorkPerEventTests {
    /// `workspaces` workspaces, each with two screens of one pane with `tabs` terminal tabs.
    private static func tree(workspaces: Int, tabs: Int) -> DaemonTree {
        var next: UInt64 = 0
        func id() -> UInt64 { next += 1; return next }
        return DaemonTree(workspaces: (0..<workspaces).map { index in
            let screens = (0..<2).map { _ in
                let pane = PaneID(rawValue: id())
                let tabs = (0..<tabs).map { _ in TabSnapshot(surface: SurfaceID(rawValue: id()), title: "~") }
                return ScreenSnapshot(id: ScreenID(rawValue: id()), layout: .leaf(pane), panes: [PaneSnapshot(id: pane, tabs: tabs)])
            }
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: id()), key: nil, name: "w\(index)", screens: screens)
        })
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"live-tree-work-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    private static func liveStore(workspaces: Int, tabs: Int) throws -> DaemonStore {
        let store = DaemonStore()
        store.connectionState = .connected(try connected())
        store.apply(snapshot: tree(workspaces: workspaces, tabs: tabs))
        return store
    }

    /// 300 workspaces, 600 panes, 2,400 tabs: an owner that follows one tab, and the pane
    /// teardown's sweep of gone page tabs, read nothing of the other 599 panes.
    @Test func followingOneTabReadsNoOtherPane() throws {
        let store = try Self.liveStore(workspaces: 300, tabs: 4)
        let tracked = try #require(store.workspaces.first?.screens.first?.panes.first?.tabs.first)
        let far = try #require(store.workspaces.last)
        let farPane = try #require(far.screens.first?.panes.first)
        let watch = GoneTabWatch()
        let pages = InternalPageTabStore()
        defer { watch.forget(tracked.id) }

        let reached = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            // A terminal's first surface: the cache starts following its tab.
            watch.track(tracked.id, in: store) { _ in }
            // A pane controller's teardown: page tabs of panes the tree no longer lists close.
            pages.closeGonePanes(in: store)
            pages.closeGoneStoreTabs(in: store)
        } onChange: {
            reached.withLock { $0 = true }
        }

        // Another workspace reorders its screens and one of its panes reorders its tabs: no tab
        // or pane came or went, and none of it is the followed tab's.
        far.screens = Array(far.screens.reversed())
        farPane.tabs = Array(farPane.tabs.reversed())
        #expect(!reached.withLock { $0 },
                "following one tab tracked every workspace's screens and every pane's tabs (O(all) per tab-list change)")
    }

    /// The narrow check keeps the rule: a followed tab goes once its live tree, having listed it,
    /// drops it (a closed workspace); a tab the tree still lists stays.
    @Test(.timeLimit(.minutes(1))) func aTabTheTreeDropsIsReleasedAndAListedOneStays() async throws {
        let store = try Self.liveStore(workspaces: 3, tabs: 2)
        let kept = try #require(store.workspaces.first?.screens.first?.panes.first?.tabs.first)
        let dropped = try #require(store.workspaces.last?.screens.first?.panes.first?.tabs.first)
        let watch = GoneTabWatch()
        let (released, release) = AsyncStream.makeStream(of: String.self)
        watch.track(kept.id, in: store) { release.yield($0) }
        watch.track(dropped.id, in: store) { release.yield($0) }
        defer {
            watch.forget(kept.id)
            watch.forget(dropped.id)
        }

        // The last workspace closes: the same tree without it.
        var tree = Self.tree(workspaces: 3, tabs: 2)
        tree.workspaces.removeLast()
        store.apply(snapshot: tree)

        var iterator = released.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first == dropped.id, "the dropped tab was not released, or the listed one was")
        #expect(watch.tracks(kept.id), "a tab the tree still lists was let go")
    }
}
