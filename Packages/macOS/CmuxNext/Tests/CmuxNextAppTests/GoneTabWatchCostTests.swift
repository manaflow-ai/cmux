@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// A tab-list change costs the gone-tab watch the tabs it tracks, not the session (CLAUDE.md "Go
/// past Chrome where cmux is scripted": a script that adds tabs, moves panes or makes columns in
/// 50 background workspaces must not make every watcher walk every tab of every workspace).
@MainActor struct GoneTabWatchCostTests {
    /// `count` workspaces of one pane with `tabs` tabs; workspace 0 gets one more tab with `grown`.
    private static func session(_ count: Int, tabs: Int = 3, grown: Bool = false) -> DaemonTree {
        DaemonTree(workspaces: (0..<count).map { index in
            let base = UInt64(index * 100)
            let extra = grown && index == 0 ? 1 : 0
            let pane = PaneSnapshot(id: PaneID(rawValue: base + 1),
                                    tabs: (0..<(tabs + extra)).map { TabSnapshot(surface: SurfaceID(rawValue: base + 10 + UInt64($0)), title: "~") })
            let screen = ScreenSnapshot(id: ScreenID(rawValue: base + 2), layout: .leaf(pane.id), panes: [pane])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: base + 3), key: nil, name: "w\(index)", screens: [screen])
        })
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"gone-tab-cost-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    private static func settle() async {
        for _ in 0..<100 { await Task.yield() }
    }

    @Test(arguments: [50, 500])
    func aTabListChangeVisitsOnlyTheTrackedTabs(sessionSize: Int) async throws {
        let store = DaemonStore()
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.session(sessionSize))
        let tracked = try #require(store.tab(surface: SurfaceID(rawValue: 100 + 10)))
        let watch = GoneTabWatch()
        var released: [String] = []
        watch.track(tracked.id, in: store) { released.append($0) }
        await Self.settle()
        let before = watch.tabsVisited

        // Another workspace gets a tab: the tab list changed, the tracked tab did not go.
        store.apply(snapshot: Self.session(sessionSize, grown: true))
        await Self.settle()

        let visited = watch.tabsVisited - before
        #expect(visited <= 2, "one tab-list change visited \(visited) tabs in a \(sessionSize)-workspace session to watch one tab")
        #expect(released.isEmpty, "a tab the tree still lists was released")
    }
}
