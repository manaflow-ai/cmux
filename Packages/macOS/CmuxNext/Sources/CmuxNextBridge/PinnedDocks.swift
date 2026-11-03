public import CmuxNextDaemon
public import CmuxNextLayout

extension DaemonStore {
    /// The pinned dock column holding `pane`, if any (`pinned-dock-v1`; Home's dock).
    public func pinnedDock(holding pane: DaemonPaneID) -> DockColumn? {
        let column = workspace(containing: pane)?.screens.lazy.flatMap(\.columns).first { $0.layout.paneIDs.contains(pane) }
        guard let dock = column?.dock.map({ LayoutMapping.dock($0) }), dock.isPinned else { return nil }
        return dock
    }

    /// Whether `pane` is a pinned dock alone on its screen, the strip's one column: a daemon with
    /// `pinned-dock-alone-v1` makes a split right of it a new column beside it, in one commit.
    public func isLonePinnedDock(_ pane: DaemonPaneID) -> Bool {
        pinnedDock(holding: pane) != nil && screen(containing: pane)?.columns.count == 1
    }
}
