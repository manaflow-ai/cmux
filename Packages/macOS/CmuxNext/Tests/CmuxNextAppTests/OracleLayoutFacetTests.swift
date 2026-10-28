#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextLayout
import CmuxNextOracle
import Foundation
import Testing

/// The oracle's layout facet (`OracleLayoutFacet`) is `LayoutModel` values in the snapshot
/// schema's form: the split, strip, column and row tree with ratios, widths and heights at 3 dp, docks on their
/// columns, the zoomed and focused pane, the strip's column count and the free canvas. Nothing the views report
/// (`visiblePanes`, frames) and no viewport-fitted zoom. The App's provider reads every workspace a window shows.
/// Run: `swift test --filter OracleLayoutFacetTests`.
@MainActor @Suite(.serialized) struct OracleLayoutFacetTests {
    private static let workspace = "ws_000000000000000000000000000000b1"

    private func leaf(_ pane: String) -> OracleValue {
        ["kind": "leaf", "axis": nil, "ratios": [], "pane": .string(pane), "children": []]
    }

    /// `layout.screens` as the facet list captures it in one main-actor turn.
    private func screens(_ facets: OracleFacets) throws -> [OracleValue] {
        let layout = try #require(try facets.beginCapture([.layout]).completed?["layout"])
        guard case .array(let screens)? = layout["screens"] else {
            Issue.record("layout has no screens array: \(layout)")
            return []
        }
        return screens
    }

    private func screens(_ model: LayoutModel) throws -> [OracleValue] {
        try screens(OracleFacets([OracleLayoutFacet { [OracleLayoutFacet.Shown(workspace: Self.workspace, model: model)] }]))
    }

    @Test func splitScreenGivesItsTreeWithRatiosAt3dpAndFocusAsOneImplicitColumn() throws {
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
            // A screen stored as one split tree is one implicit column (LayoutScreen.implicitColumnID).
            "strip": ["columns": 1],
            "canvas": nil,
        ]
        #expect(try screens(model) == [expected])
    }

    @Test func columnScreenGivesColumnsRowsAndDocksWhateverTheViewReportsVisible() throws {
        let rows = [LayoutRow(id: "row_1", height: 600, root: .leaf("pane_a")), LayoutRow(id: "row_2", height: 400, root: .leaf("pane_b"))]
        let columns = [
            LayoutColumn(id: "col_dock", width: 0.3333, root: .leaf("pane_d"), dock: DockColumn(edge: .left, mode: .overlay, role: .agentChat)),
            LayoutColumn(id: "col_1", width: 0.5, root: .split("split_r", axis: .vertical, ratio: 0.6, a: .leaf("pane_a"), b: .leaf("pane_b")),
                         rows: rows),
            LayoutColumn(id: "col_2", width: 0.75, root: .leaf("pane_c")),
        ]
        let model = LayoutModel(screens: [LayoutScreen(id: "screen_1", name: "one", layout: .columns(columns))], focusedPane: "pane_c")

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
            // The docked column is pinned, not in the strip.
            "strip": ["columns": 2],
            "canvas": nil,
        ]
        #expect(try screens(model) == [expected])
        // What the view reports visible (a scroll, a 1 px sliver, a hidden window) is view state: no change.
        model.reportVisiblePanes(["pane_d"], keepAlive: [])
        #expect(try screens(model) == [expected])
        model.reportVisiblePanes(["pane_a", "pane_c"], keepAlive: [])
        #expect(try screens(model) == [expected])
    }

    @Test func inactiveScreenHasNoFocusAndZoomNamesThePane() throws {
        let shown = LayoutScreen(id: "screen_1", name: "one", layout: .columns([LayoutColumn(id: "col_1", root: .leaf("pane_a"))]))
        let zoomed = LayoutScreen(id: "screen_2", name: "two", layout: .splits(.leaf("pane_z")), zoomed: true)
        let model = LayoutModel(screens: [shown, zoomed], activeScreenID: "screen_1", focusedPane: "pane_a")

        let result = try screens(model)
        #expect(result.count == 2)
        #expect(result.first?["active"] == true)
        #expect(result.first?["focusedPane"] == "pane_a")
        #expect(result.first?["strip"] == ["columns": 1])
        #expect(result.last?["active"] == false)
        #expect(result.last?["focusedPane"] == .null)
        #expect(result.last?["zoomedPane"] == "pane_z")
        #expect(result.last?["strip"] == ["columns": 1])
    }

    @Test func canvasScreenGivesOrderAndZoomAndNoViewportFittedZoomInTheOverview() throws {
        let tree = SplitNode.split("split_1", axis: .horizontal, ratio: 0.5, a: .leaf("pane_b"), b: .leaf("pane_a"))
        let model = LayoutModel(screens: [LayoutScreen(id: "screen_1", name: "one", layout: .splits(tree))], focusedPane: "pane_a")
        let seed: [LayoutPaneID: CGRect] = ["pane_b": CGRect(x: 0, y: 0, width: 400, height: 300),
                                      "pane_a": CGRect(x: 400, y: 0, width: 400, height: 300)]
        #expect(model.toggleCanvas(seed: seed, viewport: CGSize(width: 800, height: 300)))
        #expect(model.zoomCanvas(by: 1.25))
        model.setCanvasFrame(CGRect(x: 0, y: 0, width: 400, height: 300), for: "pane_a", raise: true)

        #expect(try screens(model).first?["canvas"] == ["order": ["pane_b", "pane_a"], "zoom": 1.25, "overview": false])
        // The overview fits the camera to the viewport the view reported: its zoom is not a model value.
        #expect(model.toggleCanvasOverview())
        #expect(try screens(model).first?["canvas"] == ["order": ["pane_b", "pane_a"], "zoom": nil, "overview": true])
        #expect(model.toggleCanvasOverview())
        #expect(try screens(model).first?["canvas"]?["zoom"] == 1.25)
    }

    /// The App's provider: every workspace a window shows, under its public `ws_…` id, from the window's own
    /// LayoutModel (the daemon's split mapped by LayoutMapping when the content mounts).
    @Test func theAppListReadsTheWorkspaceEachWindowShows() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        // No window shows a workspace: an empty screen list, not an error.
        #expect(try screens(services.makeOracleFacets()) == [])

        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self,
                                                from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        let left = PaneSnapshot(id: CmuxNextDaemon.PaneID(rawValue: 101), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 201), title: "~")])
        let right = PaneSnapshot(id: CmuxNextDaemon.PaneID(rawValue: 102), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 202), title: "~")])
        let screen = ScreenSnapshot(id: CmuxNextDaemon.ScreenID(rawValue: 101),
                                    layout: .split(id: nil, resourceID: nil, direction: .right, ratio: 0.25, a: .leaf(left.id), b: .leaf(right.id)),
                                    panes: [left, right])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "k1"), resourceID: ResourceID(rawValue: Self.workspace),
                              name: "k1", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "k1"), index: 0)])
        store.apply(snapshot: tree)
        services.windows.ordersWindowsIn = false
        let controller = try #require(services.windows.openWindow(workspaces: ["k1"], frame: CGRect(x: 120, y: 120, width: 1000, height: 700)))
        defer {
            controller.teardown()
            controller.window?.close()
        }
        controller.showWorkspace(requested: controller.state.workspaceID)
        let content = try #require(controller.content)
        let panes = content.layoutModel.screens.flatMap(\.layout.panes).map(\.rawValue)
        try #require(panes.count == 2, "the split did not map into the window's LayoutModel: \(panes)")

        let result = try screens(services.makeOracleFacets())
        #expect(result.count == 1)
        #expect(result.first?["workspace"] == .string(Self.workspace))
        #expect(result.first?["active"] == true)
        #expect(result.first?["root"] == [
            "kind": "split", "axis": "horizontal", "ratios": [0.25, 0.75], "pane": nil,
            "children": [leaf(panes[0]), leaf(panes[1])],
        ])
        #expect(result.first?["strip"] == ["columns": 1])
        #expect(result.first?["canvas"] == .null)
    }
}
#endif
