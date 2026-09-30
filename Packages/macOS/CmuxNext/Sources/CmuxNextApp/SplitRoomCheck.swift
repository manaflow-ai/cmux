import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextLayout

/// What a requested split of a shown pane does, decided from the live layout
/// geometry before any daemon command (`SplitRoom`). Every split entry point
/// (split actions, tab and tab group moves, drops) goes through
/// `AppServices.splitRoom`, so they refuse or reroute the same way.
enum SplitRoomDecision {
    /// Split in place.
    case split
    /// Columns screen with no room across: open a new column instead.
    /// `afterColumn` places a moved tab; `spawnAnchor` is the pane a new
    /// terminal column opens right of.
    case newColumn(afterColumn: DaemonColumnID?, spawnAnchor: DaemonPaneID)
    /// No room; the localized reason for the caller to report.
    case refused(String)
}

extension AppServices {
    /// The decision for splitting `pane` on `edge`. `source` is the pane a
    /// moved tab leaves; when that was its only tab the pane disappears in
    /// the same step, which frees room. A pane no window shows (a background
    /// workspace driven from the CLI) always splits: nothing is measured.
    func splitRoom(for pane: PaneModel, edge: PaneEdge, movingFrom source: PaneModel? = nil) -> SplitRoomDecision {
        guard let controller = paneController(for: pane), let content = controller.workspace else { return .split }
        let layoutPane = controller.layoutPaneID
        let axis: SplitAxis = edge == .left || edge == .right ? .horizontal : .vertical
        let removing = source.flatMap { source -> LayoutPaneID? in
            guard source !== pane, source.tabs.count == 1 else { return nil }
            return content.handles.paneIDs[source.handle]
        }
        switch content.layoutView.splitPlacement(splitting: layoutPane, axis: axis, removing: removing) {
        case .split:
            return .split
        case .refused(.notEnoughRoom):
            return .refused(RefusalStrings.notEnoughRoomToSplit)
        case .newColumn:
            let columns = content.layoutModel.screen(containing: layoutPane)?.layout.columns ?? []
            guard let index = columns.firstIndex(where: { $0.root.contains(layoutPane) }) else { return .split }
            // A leading-edge request goes after the previous column; before
            // the first column there is no slot, so it goes right.
            if edge == .left, index > 0, let previous = columns[index - 1].root.panes.last,
               let anchor = content.handles.panes[previous] {
                return .newColumn(afterColumn: content.handles.columns[columns[index - 1].id], spawnAnchor: anchor)
            }
            return .newColumn(afterColumn: content.handles.columns[columns[index].id], spawnAnchor: pane.handle)
        }
    }

    /// The width to send with a new column next to `pane`, from every path
    /// that opens one. On a shown workspace it also shrinks a lone
    /// full-width column so both fit (`LayoutModel.prepareNewColumn`, an
    /// optimistic width intent). `source` is the pane a moved tab leaves.
    func newColumnWidth(nextTo pane: PaneModel, movingFrom source: PaneModel? = nil) -> Double {
        guard let controller = paneController(for: pane), let content = controller.workspace else {
            return DesignSettings.shared.defaultColumnWidth
        }
        // A pane whose only tab moves out closes, even the anchor itself.
        let removing = source.flatMap { $0.tabs.count == 1 ? content.handles.paneIDs[$0.handle] : nil }
        return content.layoutModel.prepareNewColumn(nextTo: controller.layoutPaneID, removing: removing)
    }
}
