#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextLayout
public import CmuxNextOracle

/// The oracle's `layout` facet (schemas/oracle/snapshot-v1.schema.json `layout`): per screen of
/// each workspace a window shows, the split, strip, column and row tree with ratios, widths and heights at 3 dp,
/// docks on their columns, whether the screen is active, its focused and zoomed pane, the strip's column count and
/// the free canvas. Model values only: nothing the views report (frames, `LayoutModel.visiblePanes`, the strip's
/// scroll offset) and nothing fitted to the viewport, so two builds that hold the same model give the same facet
/// whatever the window size. Blink's web-test layout dumps print the layout objects' values, not pixels, the same
/// way (third_party/blink/renderer/core/layout/layout_tree_as_text.cc).
public nonisolated struct OracleLayoutFacet: OracleFacetProvider {
    /// One workspace a window shows: its public id (`ws_…`, as `snapshot.get` prints it) and its layout.
    public nonisolated struct Shown {
        public var workspace: String
        public var model: LayoutModel

        public init(workspace: String, model: LayoutModel) {
            self.workspace = workspace
            self.model = model
        }
    }

    public var facet: OracleFacet { .layout }
    public let capture: OracleFacetCapture

    /// - Parameter shown: The workspaces the windows show now, read in the snapshot's main-actor turn.
    public init(shown: @escaping @MainActor @Sendable () throws(OracleFacetError) -> [Shown]) {
        capture = .mainActor { () throws(OracleFacetError) -> OracleValue in
            let workspaces = try shown()
            return ["screens": .array(workspaces.flatMap { Self.screens(of: $0.model, workspace: $0.workspace) })]
        }
    }

    /// One `layout.screens` entry per screen of `model`, in model order.
    @MainActor static func screens(of model: LayoutModel, workspace: String) -> [OracleValue] {
        model.screens.map { screen -> OracleValue in
            let focused = model.focusedPane.flatMap { screen.layout.contains($0) ? $0 : nil }
            return [
                "workspace": .string(workspace),
                "screen": .string(screen.id.rawValue),
                "active": .bool(screen.id == model.activeScreenID),
                "root": node(screen.layout),
                "focusedPane": pane(focused),
                "zoomedPane": pane(zoomedPane(screen)),
                "strip": ["columns": OracleValue(stripColumns(screen.layout))],
                "canvas": model.canvas(for: screen.id).map(canvas) ?? .null,
            ]
        }
    }

    /// The strip's scrolling columns: a screen stored as one split tree is one implicit column
    /// (`LayoutScreen.implicitColumnID`); docked columns are pinned, not in the strip.
    private static func stripColumns(_ layout: ScreenLayout) -> Int {
        switch layout {
        case .splits: 1
        case .columns(let columns): columns.filter { $0.dock == nil }.count
        }
    }

    /// A zoomed screen's layout is its one zoomed pane (LayoutMapping).
    private static func zoomedPane(_ screen: LayoutScreen) -> LayoutPaneID? {
        guard screen.zoomed, case .splits(.leaf(let pane)) = screen.layout else { return nil }
        return pane
    }

    private static func node(_ layout: ScreenLayout) -> OracleValue {
        switch layout {
        case .splits(let root):
            node(root)
        case .columns(let columns):
            node(kind: "strip", axis: .horizontal, children: columns.map(node(column:)))
        }
    }

    private static func node(_ split: SplitNode) -> OracleValue {
        switch split {
        case .leaf(let leaf):
            node(kind: "leaf", pane: leaf)
        case .split(_, let axis, let ratio, let a, let b):
            node(kind: "split", axis: axis, ratios: [ratio, 1 - ratio], children: [node(a), node(b)])
        }
    }

    /// A column holds its rows when it has two or more, else its one tree.
    private static func node(column: LayoutColumn) -> OracleValue {
        let children = column.hasRows ? column.rows.map(node(row:)) : [node(column.root)]
        return node(kind: "column", axis: .vertical, children: children,
                    extra: ["width": number(column.width), "dock": column.dock.map(dock) ?? .null])
    }

    /// Row heights are permille of the column's height.
    private static func node(row: LayoutRow) -> OracleValue {
        node(kind: "row", children: [node(row.root)], extra: ["height": number(Double(row.height) / 1000)])
    }

    private static func dock(_ dock: DockColumn) -> OracleValue {
        [
            "edge": .string(dock.edge.rawValue),
            "mode": .string(dock.mode.rawValue),
            "role": dock.role.map { .string($0.rawValue) } ?? .null,
            "pinned": .bool(dock.isPinned),
            "allowsTabs": .bool(dock.allowsTabs),
        ]
    }

    /// Frames are left out: a canvas seeds them from the view's frames when it opens. In the overview the camera
    /// is fitted to the viewport (`CanvasCamera.fitting`), so its zoom is null there.
    private static func canvas(_ canvas: CanvasScreen) -> OracleValue {
        let overview = canvas.overviewReturn != nil
        return [
            "order": .array(canvas.order.map { .string($0.rawValue) }),
            "zoom": overview ? .null : number(canvas.camera.zoom),
            "overview": .bool(overview),
        ]
    }

    /// One `layoutNode`: the five keys every kind has, plus a column's `width` and `dock` or a row's `height`.
    private static func node(kind: String, axis: SplitAxis? = nil, ratios: [Double] = [], pane leaf: LayoutPaneID? = nil,
                             children: [OracleValue] = [], extra: [String: OracleValue] = [:]) -> OracleValue {
        let members: [String: OracleValue] = [
            "kind": .string(kind),
            "axis": axis.map { .string($0.rawValue) } ?? .null,
            "ratios": .array(ratios.map(number)),
            "pane": pane(leaf),
            "children": .array(children),
        ]
        return .object(members.merging(extra) { _, added in added })
    }

    private static func pane(_ pane: LayoutPaneID?) -> OracleValue {
        pane.map { .string($0.rawValue) } ?? .null
    }

    /// 3 dp, the schema's `x-oracle-precision` for ratios, widths, heights and zoom.
    private static func number(_ value: Double) -> OracleValue {
        .number((value * 1000).rounded() / 1000)
    }
}
#endif
