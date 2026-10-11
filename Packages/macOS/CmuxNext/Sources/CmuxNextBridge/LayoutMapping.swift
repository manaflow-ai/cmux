public import CmuxNextDaemon
public import CmuxNextLayout

/// Maps one daemon workspace (screens, split trees, scrolling columns) into
/// `LayoutScreen`s keyed by durable ids.
///
/// Rules (REWRITE.md Integration notes): a daemon `stack` becomes one leaf
/// showing its expanded pane; a zoomed pane fills its screen; unknown node
/// types drop out and their sibling takes the space.
public struct LayoutMapping {
    public static let shared = Self()
    public struct Result: Equatable, Sendable {
        public var screens: [LayoutScreen]
        public var handles: LayoutHandleMap
    }

    public func map(_ workspace: WorkspaceModel) -> Result {
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

    func layout(of screen: ScreenModel, paneIDs: [DaemonPaneID: LayoutPaneID],
                       handles: inout LayoutHandleMap) -> ScreenLayout? {
        if let zoomed = screen.zoomedPane, let id = paneIDs[zoomed] {
            return .splits(.leaf(id))
        }
        if !screen.columns.isEmpty {
            let columns = screen.columns.compactMap { self.column($0, paneIDs: paneIDs, handles: &handles) }
            return columns.isEmpty ? nil : .columns(columns)
        }
        return node(screen.layout, paneIDs: paneIDs, handles: &handles).map(ScreenLayout.splits)
    }

    /// One daemon column. Its rows (`rows-v1`) map with their trees; a row
    /// with nothing to show drops out, and one row left is a column
    /// without rows. `root` stays the compat chain.
    public func column(_ column: ColumnSnapshot, paneIDs: [DaemonPaneID: LayoutPaneID],
                       handles: inout LayoutHandleMap) -> LayoutColumn? {
        guard let root = node(column.layout, paneIDs: paneIDs, handles: &handles) else { return nil }
        let id = LayoutHandleMap.columnID(column.id)
        handles.columns[id] = column.id
        let width = min(max(column.width, ColumnWidthPreset.widthRange.lowerBound), ColumnWidthPreset.widthRange.upperBound)
        var rows: [LayoutRow] = []
        var rowHandles: [LayoutRowID: DaemonRowID] = [:]
        for row in column.rows {
            guard let tree = node(row.layout, paneIDs: paneIDs, handles: &handles) else { continue }
            let rowID = LayoutHandleMap.rowID(row.id)
            rowHandles[rowID] = row.id
            let height = min(max(row.height, LayoutRow.heightRange.lowerBound), LayoutRow.heightRange.upperBound)
            rows.append(LayoutRow(id: rowID, height: height, root: tree))
        }
        if rows.count < 2 {
            rows = []
        } else {
            handles.rows.merge(rowHandles) { _, new in new }
        }
        return LayoutColumn(id: id, width: width, root: root, dock: column.dock.map(Self.dock), rows: rows)
    }

    /// Daemon `columns[].dock` as the layout's dock.
    public nonisolated static func dock(_ snapshot: DockSnapshot) -> DockColumn {
        let edge: DockEdge = switch snapshot.edge {
        case .left: .left
        case .right: .right
        case .top: .top
        case .bottom: .bottom
        }
        return DockColumn(edge: edge, mode: snapshot.mode == .overlay ? .overlay : .docked,
                          role: snapshot.role.map { _ in .agentChat })
    }

    /// The layout's dock as the daemon's value. Top and bottom need a daemon
    /// that serves `edge-docks-v1`; `ColumnDocking.apply` and the
    /// intent sender check that before sending.
    public nonisolated static func snapshot(_ dock: DockColumn) -> DockSnapshot {
        let edge: DockSnapshot.Edge = switch dock.edge {
        case .left: .left
        case .right: .right
        case .top: .top
        case .bottom: .bottom
        }
        return DockSnapshot(edge: edge, mode: dock.mode == .overlay ? .overlay : .docked,
                            role: dock.role.map { _ in .agentChat })
    }

    /// Converts one daemon layout node. Nil when nothing in it can be shown.
    public func node(_ node: LayoutNode, paneIDs: [DaemonPaneID: LayoutPaneID],
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
