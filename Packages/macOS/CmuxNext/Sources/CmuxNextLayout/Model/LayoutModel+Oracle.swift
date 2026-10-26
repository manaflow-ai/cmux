#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextOracle

/// The oracle's `layout` facet (p15-oracle-035, schemas/oracle/snapshot-v1.schema.json `layout`): model
/// values only, never a view frame or the view tree, so two builds that put the same model on screen give the
/// same facet whatever their views do. Blink's web-test layout dumps work the same way: they print the layout
/// objects' values, not pixels (third_party/blink/renderer/core/layout/layout_tree_as_text.cc).
extension LayoutModel {
    /// One `layout.screens` entry per screen, in model order: the split, strip, column and row tree with
    /// ratios, widths and heights at 3 dp, docks on their columns, whether the screen is active, its focused
    /// and zoomed pane, the strip's first visible column and the free canvas. `workspace` is the workspace's
    /// public id (`ws_…`, as `snapshot.get` prints it).
    public func oracleScreens(workspace: String) -> [OracleValue] {
        screens.map { oracleScreen($0, workspace: workspace) }
    }

    private func oracleScreen(_ screen: LayoutScreen, workspace: String) -> OracleValue {
        let active = screen.id == activeScreenID
        let focused = focusedPane.flatMap { screen.layout.contains($0) ? $0 : nil }
        let scrolling = screen.layout.columns.filter { $0.dock == nil }
        // Only the active screen's panes are reported visible (LayoutRootView reports its shown screen).
        let visible: Set<PaneID> = active ? visiblePanes : []
        let firstVisible = scrolling.firstIndex(where: { column in column.root.panes.contains(where: { visible.contains($0) }) })
        let strip: OracleValue = [
            "columns": OracleValue(scrolling.count),
            "firstVisibleColumn": firstVisible.map { OracleValue($0) } ?? .null,
        ]
        return [
            "workspace": .string(workspace),
            "screen": .string(screen.id.rawValue),
            "active": .bool(active),
            "root": screen.layout.oracleNode,
            "focusedPane": .oraclePane(focused),
            "zoomedPane": .oraclePane(screen.zoomedPane),
            "strip": strip,
            "canvas": canvas(for: screen.id)?.oracleValue ?? .null,
        ]
    }
}

private extension LayoutScreen {
    /// A zoomed screen's layout is its one zoomed pane (LayoutMapping).
    var zoomedPane: PaneID? {
        guard zoomed, case .splits(.leaf(let pane)) = layout else { return nil }
        return pane
    }
}

private extension ScreenLayout {
    var oracleNode: OracleValue {
        switch self {
        case .splits(let root):
            return root.oracleNode
        case .columns(let columns):
            return .oracleNode(kind: "strip", axis: .horizontal, children: columns.map { $0.oracleNode })
        }
    }
}

private extension SplitNode {
    var oracleNode: OracleValue {
        switch self {
        case .leaf(let pane):
            return .oracleNode(kind: "leaf", pane: pane)
        case .split(_, let axis, let ratio, let a, let b):
            return .oracleNode(kind: "split", axis: axis, ratios: [ratio, 1 - ratio], children: [a.oracleNode, b.oracleNode])
        }
    }
}

private extension LayoutColumn {
    /// A column holds its rows when it has two or more, else its one tree.
    var oracleNode: OracleValue {
        let children = hasRows ? rows.map { $0.oracleNode } : [root.oracleNode]
        return .oracleNode(kind: "column", axis: .vertical, children: children,
                           extra: ["width": .oracleNumber(width), "dock": dock?.oracleValue ?? .null])
    }
}

private extension LayoutRow {
    var oracleNode: OracleValue {
        .oracleNode(kind: "row", children: [root.oracleNode], extra: ["height": .oracleNumber(Double(height) / 1000)])
    }
}

private extension DockColumn {
    var oracleValue: OracleValue {
        [
            "edge": .string(edge.rawValue),
            "mode": .string(mode.rawValue),
            "role": role.map { .string($0.rawValue) } ?? .null,
            "pinned": .bool(isPinned),
            "allowsTabs": .bool(allowsTabs),
        ]
    }
}

private extension CanvasScreen {
    /// Frames are left out: a canvas seeds them from the view's frames when it opens.
    var oracleValue: OracleValue {
        [
            "order": .array(order.map { .string($0.rawValue) }),
            "zoom": .oracleNumber(camera.zoom),
            "overview": .bool(overviewReturn != nil),
        ]
    }
}

private extension OracleValue {
    /// One `layoutNode`: the five keys every kind has, plus a column's `width` and `dock` or a row's `height`.
    static func oracleNode(kind: String, axis: SplitAxis? = nil, ratios: [Double] = [], pane: PaneID? = nil,
                           children: [OracleValue] = [], extra: [String: OracleValue] = [:]) -> OracleValue {
        let members: [String: OracleValue] = [
            "kind": .string(kind),
            "axis": axis.map { .string($0.rawValue) } ?? .null,
            "ratios": .array(ratios.map { .oracleNumber($0) }),
            "pane": .oraclePane(pane),
            "children": .array(children),
        ]
        return .object(members.merging(extra) { _, added in added })
    }

    static func oraclePane(_ pane: PaneID?) -> OracleValue {
        pane.map { .string($0.rawValue) } ?? .null
    }

    /// 3 dp, the schema's `x-oracle-precision` for ratios, widths, heights and zoom.
    static func oracleNumber(_ value: Double) -> OracleValue {
        .number((value * 1000).rounded() / 1000)
    }
}
#endif
