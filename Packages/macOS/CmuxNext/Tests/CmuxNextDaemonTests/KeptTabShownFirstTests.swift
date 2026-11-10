import Foundation
import Testing
@testable import CmuxNextDaemon

/// The restore of a session (the connect after End Sessions, Keep Layout or an update) asks the
/// daemon for the kept tabs of the workspaces a window shows first. The daemon starts the
/// restarts in the order of the requests, a few at a time, so in tree order alone the terminal
/// the person looks at came after every kept tab above it in the sidebar (170 in the person's
/// session).
@Suite struct KeptTabShownFirstTests {
    private static func key(_ index: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", index) }

    /// Workspace `index` with the kept tabs `surfaces` (dead, a `relaunch` record, not parked).
    private static func workspace(_ index: Int, surfaces: [Int], parked: Bool = false) -> WorkspaceSnapshot {
        let pane = PaneID(rawValue: 1000 + index)
        let tabs = surfaces.map { surface in
            var tab = TabSnapshot(surface: SurfaceID(rawValue: surface), dead: true)
            tab.relaunch = TabRelaunch(cwd: "/tmp/work", onShow: parked)
            return tab
        }
        return WorkspaceSnapshot(
            id: WorkspaceHandle(rawValue: index), key: WorkspaceKey(rawValue: key(index)), name: "\(index)",
            screens: [ScreenSnapshot(id: ScreenID(rawValue: 2000 + index), active: true, activePane: pane, layout: .leaf(pane),
                                     panes: [PaneSnapshot(id: pane, tabs: tabs)])])
    }

    private static func tree() -> DaemonTree {
        DaemonTree(workspaces: [
            workspace(1, surfaces: [11, 12]), workspace(2, surfaces: [21]), workspace(3, surfaces: [31, 32]),
            workspace(4, surfaces: [41]),
        ])
    }

    private static func order(shown: Set<String>) -> [Int] {
        KeptTabRelaunch.steps(tree: tree(), home: "/Users/someone", shown: shown).map(\.surface.rawValue)
    }

    @Test func theKeptTabsOfTheShownWorkspacesAreAskedForFirst() {
        #expect(Self.order(shown: [Self.key(3)]) == [31, 32, 11, 12, 21, 41])
        // Two windows: each one's workspace, in tree order, then the rest in tree order.
        #expect(Self.order(shown: [Self.key(4), Self.key(2)]) == [21, 41, 11, 12, 31, 32])
    }

    @Test func withNoShownWorkspaceTheOrderIsTheTreeOrderAndNoTabIsLost() {
        #expect(Self.order(shown: []) == [11, 12, 21, 31, 32, 41])
        // A shown workspace this daemon does not have (another machine's) changes nothing.
        #expect(Self.order(shown: ["some-other-workspace"]) == [11, 12, 21, 31, 32, 41])
    }

    /// A parked tab of a shown workspace still waits for the show (`wakeParkedTabs`): it is not
    /// a step of the connect.
    @Test func aParkedTabOfAShownWorkspaceIsNotAStepOfTheConnect() {
        let tree = DaemonTree(workspaces: [Self.workspace(1, surfaces: [11]), Self.workspace(2, surfaces: [21], parked: true)])
        let steps = KeptTabRelaunch.steps(tree: tree, home: "/Users/someone", shown: [Self.key(2)])
        #expect(steps.map(\.surface.rawValue) == [11])
    }
}
