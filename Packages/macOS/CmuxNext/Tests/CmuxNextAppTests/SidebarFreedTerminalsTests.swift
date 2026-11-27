import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// The freeing tier in the sidebar: a workspace whose idle shells were freed counts them in its hover card.
@MainActor @Suite(.serialized) struct SidebarFreedTerminalsTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// A workspace whose idle shells the freeing tier ended (`park-tabs`: dead, `relaunch.on_show`) says so in its
    /// hover card, with how many; a dead tab that is not parked, and a live one, do not count.
    @Test func theHoverCardCountsTheFreedTerminals() throws {
        let pane = PaneID(rawValue: 3)
        var parked = TabSnapshot(surface: SurfaceID(rawValue: 4), dead: true)
        parked.relaunch = TabRelaunch(cwd: "/tmp", onShow: true)
        var keptAtConnect = TabSnapshot(surface: SurfaceID(rawValue: 5), dead: true)
        keptAtConnect.relaunch = TabRelaunch(cwd: "/tmp")
        let tabs = [parked, keptAtConnect, TabSnapshot(surface: SurfaceID(rawValue: 6))]
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [WorkspaceSnapshot(
            id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "w1"), name: "freed",
            screens: [ScreenSnapshot(id: ScreenID(rawValue: 2), active: true, activePane: pane, layout: .leaf(pane),
                                     panes: [PaneSnapshot(id: pane, tabs: tabs)])])]))
        let row = SidebarMapping.shared.row(try #require(store.workspaces.first), machine: .local)
        #expect(row.tabs.map(\.isFreed) == [true, false, false])
        let freed = WorkspaceHoverCardContent.make(row, machine: nil, now: Self.t0).facts.filter { $0.kind == "freed" }
        #expect(freed.map(\.text) == [Strings.freedTerminals(1)])
    }
}
