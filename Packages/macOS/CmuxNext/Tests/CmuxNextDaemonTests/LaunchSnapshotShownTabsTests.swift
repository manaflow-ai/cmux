@testable import CmuxNextDaemon
import Testing

/// #17587 review: the launch decodes the panes' last frames in the order the first windows show
/// them; the launch snapshot names those panes (`LaunchSnapshot.shownTabKeys`).
@Suite struct LaunchSnapshotShownTabsTests {
    /// Two windows: the back one (order 1) shows workspace `b`, the front one (order 0) workspace
    /// `a`, whose second pane selected its second tab.
    @Test func theFrontWindowsSelectedTabsComeFirstThenTheNextWindows() {
        let paneA1 = PaneSnapshot(id: 1, resourceID: "pane_a1", tabs: [TabSnapshot(surface: 1, tabResourceID: "tab_a1", title: "")])
        let paneA2 = PaneSnapshot(id: 2, resourceID: "pane_a2", tabs: [TabSnapshot(surface: 2, tabResourceID: "tab_a2", title: ""),
                                                                      TabSnapshot(surface: 3, tabResourceID: "tab_a3", title: "")])
        let paneB = PaneSnapshot(id: 3, resourceID: "pane_b", tabs: [TabSnapshot(surface: 4, tabResourceID: "tab_b1", title: "")])
        let hidden = PaneSnapshot(id: 4, resourceID: "pane_c", tabs: [TabSnapshot(surface: 5, tabResourceID: "tab_c1", title: "")])
        let tree = DaemonTree(workspaces: [
            WorkspaceSnapshot(id: 1, key: "a", name: "a", screens: [ScreenSnapshot(id: 1, active: true, layout: .leaf(1), panes: [paneA1, paneA2])]),
            WorkspaceSnapshot(id: 2, key: "b", name: "b", screens: [ScreenSnapshot(id: 2, active: true, layout: .leaf(3), panes: [paneB])]),
            WorkspaceSnapshot(id: 3, key: "c", name: "c", active: true, screens: [ScreenSnapshot(id: 3, active: true, layout: .leaf(4), panes: [hidden])]),
        ])
        let windows = WindowStateDocument(windows: [
            WindowRecord(id: "back", workspaceKey: "b", order: 1),
            WindowRecord(id: "front", workspaceKey: "a", selectedTabs: ["pane_a2": "tab_a3"], order: 0),
        ])
        let snapshot = LaunchSnapshot(tree: tree, windows: windows, session: "s", writtenAtMs: nil)
        #expect(snapshot.shownTabKeys == ["tab_a1", "tab_a3", "tab_b1"], "a workspace no window shows decodes last")
    }

    /// Without window records the active workspace's selected tabs are the shown ones.
    @Test func withoutWindowRecordsTheActiveWorkspaceIsShown() {
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, tabResourceID: "tab_1", title: "")])
        let tree = DaemonTree(workspaces: [
            WorkspaceSnapshot(id: 1, key: "a", name: "a", screens: []),
            WorkspaceSnapshot(id: 2, key: "b", name: "b", active: true, screens: [ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])]),
        ])
        #expect(LaunchSnapshot(tree: tree, windows: nil, session: "s", writtenAtMs: nil).shownTabKeys == ["tab_1"])
    }
}
