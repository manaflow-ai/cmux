#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextApp
import CmuxNextLayout
import CmuxNextOracle
import Testing

/// The oracle's layout facet (p15-oracle-035) is `LayoutModel` values in the snapshot schema's form: the
/// split, strip, column and row tree with ratios, widths and heights at 3 dp, docks on their columns, the
/// zoomed and focused pane, the strip's first visible column and the free canvas. No view is built.
/// Run: `swift test --filter OracleLayoutFacetTests`.
@MainActor struct OracleLayoutFacetTests {
    private static let workspace = "ws_000000000000000000000000000000b1"

    private func leaf(_ pane: String) -> OracleValue {
        ["kind": "leaf", "axis": nil, "ratios": [], "pane": .string(pane), "children": []]
    }

    private func screens(_ model: LayoutModel) -> [OracleValue] {
        model.oracleScreens(workspace: Self.workspace)
    }

    @Test func splitScreenGivesItsTreeWithRatiosAt3dpAndFocus() {
        let tree = SplitNode.split("split_1", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("pane_a"),
                                   b: .split("split_2", axis: .vertical, ratio: 0.62549, a: .leaf("pane_b"), b: .leaf("pane_c")))
        let model = LayoutModel(screens: [LayoutScreen(id: "screen_1", name: "one", layout: .splits(tree))], focusedPane: "pane_b")

        let expected: OracleValue = [
            "workspace": .string(Self.workspace), "screen": "screen_1", "active": true,
            "root": [
                "kind": "split", "axis": "horizontal", "ratios": [0.333, 0.667], "pane": nil,
                "children": [
                    leaf("pane_a"),
                    ["kind": "split", "axis": "vertical", "ratios": [0.625, 0.375], "pane": nil,
                     "children": [leaf("pane_b"), leaf("pane_c")]],
                ],
            ],
            "focusedPane": "pane_b", "zoomedPane": nil,
            "strip": ["columns": 0, "firstVisibleColumn": nil],
            "canvas": nil,
        ]
        #expect(screens(model) == [expected])
    }

    @Test func columnScreenGivesColumnsRowsDocksAndTheFirstVisibleColumn() {
        let rows = [LayoutRow(id: "row_1", height: 600, root: .leaf("pane_a")), LayoutRow(id: "row_2", height: 400, root: .leaf("pane_b"))]
        let columns = [
            LayoutColumn(id: "col_dock", width: 0.3333, root: .leaf("pane_d"), dock: DockColumn(edge: .left, mode: .overlay, role: .agentChat)),
            LayoutColumn(id: "col_1", width: 0.5, root: .split("split_r", axis: .vertical, ratio: 0.6, a: .leaf("pane_a"), b: .leaf("pane_b")),
                         rows: rows),
            LayoutColumn(id: "col_2", width: 0.75, root: .leaf("pane_c")),
        ]
        let model = LayoutModel(screens: [LayoutScreen(id: "screen_1", name: "one", layout: .columns(columns))], focusedPane: "pane_c")
        model.reportVisiblePanes(["pane_c", "pane_d"], keepAlive: [])

        let dock: OracleValue = ["edge": "left", "mode": "overlay", "role": "agentChat", "pinned": false, "allowsTabs": false]
        let expected: OracleValue = [
            "workspace": .string(Self.workspace), "screen": "screen_1", "active": true,
            "root": [
                "kind": "strip", "axis": "horizontal", "ratios": [], "pane": nil,
                "children": [
                    ["kind": "column", "axis": "vertical", "ratios": [], "pane": nil, "width": 0.333, "dock": dock,
                     "children": [leaf("pane_d")]],
                    ["kind": "column", "axis": "vertical", "ratios": [], "pane": nil, "width": 0.5, "dock": nil,
                     "children": [
                         ["kind": "row", "axis": nil, "ratios": [], "pane": nil, "height": 0.6, "children": [leaf("pane_a")]],
                         ["kind": "row", "axis": nil, "ratios": [], "pane": nil, "height": 0.4, "children": [leaf("pane_b")]],
                     ]],
                    ["kind": "column", "axis": "vertical", "ratios": [], "pane": nil, "width": 0.75, "dock": nil,
                     "children": [leaf("pane_c")]],
                ],
            ],
            "focusedPane": "pane_c", "zoomedPane": nil,
            // The docked column is not in the strip: pane_c's column is the strip's second.
            "strip": ["columns": 2, "firstVisibleColumn": 1],
            "canvas": nil,
        ]
        #expect(screens(model) == [expected])
    }

    @Test func inactiveScreenHasNoFocusNoVisibleColumnAndZoomNamesThePane() {
        let shown = LayoutScreen(id: "screen_1", name: "one", layout: .columns([LayoutColumn(id: "col_1", root: .leaf("pane_a"))]))
        let zoomed = LayoutScreen(id: "screen_2", name: "two", layout: .splits(.leaf("pane_z")), zoomed: true)
        let model = LayoutModel(screens: [shown, zoomed], activeScreenID: "screen_1", focusedPane: "pane_a")
        model.reportVisiblePanes(["pane_a"], keepAlive: [])

        let result = screens(model)
        #expect(result.count == 2)
        #expect(result.first?["active"] == true)
        #expect(result.first?["strip"] == ["columns": 1, "firstVisibleColumn": 0])
        #expect(result.last?["active"] == false)
        #expect(result.last?["focusedPane"] == .null)
        #expect(result.last?["zoomedPane"] == "pane_z")
        #expect(result.last?["strip"] == ["columns": 0, "firstVisibleColumn": nil])
    }

    @Test func canvasScreenGivesOrderZoomAndOverview() {
        let tree = SplitNode.split("split_1", axis: .horizontal, ratio: 0.5, a: .leaf("pane_b"), b: .leaf("pane_a"))
        let model = LayoutModel(screens: [LayoutScreen(id: "screen_1", name: "one", layout: .splits(tree))], focusedPane: "pane_a")
        let seed: [PaneID: CGRect] = ["pane_b": CGRect(x: 0, y: 0, width: 400, height: 300),
                                      "pane_a": CGRect(x: 400, y: 0, width: 400, height: 300)]
        #expect(model.toggleCanvas(seed: seed, viewport: CGSize(width: 800, height: 300)))
        #expect(model.zoomCanvas(by: 1.25))
        model.setCanvasFrame(CGRect(x: 0, y: 0, width: 400, height: 300), for: "pane_a", raise: true)

        #expect(screens(model).first?["canvas"] == ["order": ["pane_b", "pane_a"], "zoom": 1.25, "overview": false])
        #expect(model.toggleCanvasOverview())
        #expect(screens(model).first?["canvas"]?["overview"] == true)
    }

    @Test func theAppListProvidesTheLayoutFacet() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let facets = services.makeOracleFacets()
        #expect(facets.provided.contains(.layout))
        // No window shows a workspace: the facet is an empty screen list, not an error.
        let capture = try facets.beginCapture([.layout])
        #expect(capture.completed == ["layout": ["screens": []]])
    }
}
#endif
