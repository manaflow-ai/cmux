public import CmuxNextDaemon
public import CmuxNextLayout

/// Maps one daemon workspace (screens, split trees, scrolling columns) into
/// `LayoutScreen`s keyed by durable ids.
///
/// Rules (REWRITE.md Integration notes): a daemon `stack` becomes one leaf
/// showing its expanded pane; a zoomed pane fills its screen; unknown node
/// types drop out and their sibling takes the space.
public enum LayoutMapping {
    public struct Result: Equatable, Sendable {
        public var screens: [LayoutScreen]
        public var handles: LayoutHandleMap
    }

    public static func map(_ workspace: WorkspaceModel) -> Result {
        var handles = LayoutHandleMap()
        var screens: [LayoutScreen] = []
        for screen in workspace.screens {
            var paneIDs: [DaemonPaneID: LayoutPaneID] = [:]
            for pane in screen.panes {
                let id = LayoutPaneID(pane.id)
                paneIDs[pane.handle] = id
                handles.addPane(id, handle: pane.handle)
            }
            let screenID = LayoutScreenID(screen.id)
            handles.screens[screenID] = screen.handle
            guard let layout = layout(of: screen, paneIDs: paneIDs, handles: &handles) else { continue }
            screens.append(LayoutScreen(id: screenID, name: screen.name ?? "", layout: layout))
        }
        return Result(screens: screens, handles: handles)
    }

    static func layout(of screen: ScreenModel, paneIDs: [DaemonPaneID: LayoutPaneID],
                       handles: inout LayoutHandleMap) -> ScreenLayout? {
        if let zoomed = screen.zoomedPane, let id = paneIDs[zoomed] {
            return .splits(.leaf(id))
        }
        if !screen.columns.isEmpty {
            let columns = screen.columns.compactMap { column -> LayoutColumn? in
                guard let root = node(column.layout, paneIDs: paneIDs, handles: &handles) else { return nil }
                let id = LayoutHandleMap.columnID(column.id)
                handles.columns[id] = column.id
                let width = min(max(column.width, ColumnWidthPreset.widthRange.lowerBound), ColumnWidthPreset.widthRange.upperBound)
                return LayoutColumn(id: id, width: width, root: root)
            }
            return columns.isEmpty ? nil : .columns(columns)
        }
        return node(screen.layout, paneIDs: paneIDs, handles: &handles).map(ScreenLayout.splits)
    }

    /// Converts one daemon layout node. Nil when nothing in it can be shown.
    public static func node(_ node: LayoutNode, paneIDs: [DaemonPaneID: LayoutPaneID],
                            handles: inout LayoutHandleMap) -> SplitNode? {
        switch node {
        case .leaf(let pane):
            return paneIDs[pane].map(SplitNode.leaf)
        case .stack(let panes, let expanded):
            let shown = paneIDs[expanded] ?? panes.lazy.compactMap { paneIDs[$0] }.first
            return shown.map(SplitNode.leaf)
        case .split(let splitHandle, let direction, let ratio, let a, let b):
            let first = self.node(a, paneIDs: paneIDs, handles: &handles)
            let second = self.node(b, paneIDs: paneIDs, handles: &handles)
            guard let first else { return second }
            guard let second else { return first }
            let id = LayoutHandleMap.splitID(splitHandle, firstPane: first.panes.first)
            if let splitHandle { handles.splits[id] = splitHandle }
            let axis: SplitAxis = direction == .right ? .horizontal : .vertical
            let clamped = min(max(ratio, SplitRatio.range.lowerBound), SplitRatio.range.upperBound)
            return .split(id, axis: axis, ratio: clamped, a: first, b: second)
        case .unknown:
            return nil
        }
    }
}
