import Foundation
import Testing
@testable import CmuxNestedTopology

@Suite struct RemoteHerdrWindowMirrorTests {
    private func leaf(
        _ paneID: String,
        width: Int = 80,
        height: Int = 24,
        x: Int = 0,
        y: Int = 0
    ) -> RemoteHerdrLayoutNode {
        RemoteHerdrLayoutNode(width: width, height: height, x: x, y: y, content: .pane(paneID))
    }

    private func horizontalSplit() -> RemoteHerdrLayoutNode {
        RemoteHerdrLayoutNode(
            width: 200,
            height: 50,
            x: 0,
            y: 0,
            content: .horizontal([
                leaf("w2:p1", width: 100, height: 50, x: 0, y: 0),
                leaf("w2:p2", width: 99, height: 50, x: 101, y: 0),
            ])
        )
    }

    private func window(
        layout: RemoteHerdrLayoutNode,
        tabID: String = "w2:t1",
        title: String = "Build",
        orderIndex: Int = 0,
        zoomed: Bool = false,
        visibleLayout: RemoteHerdrLayoutNode? = nil,
        activePaneID: String? = nil
    ) -> RemoteHerdrWindow {
        RemoteHerdrWindow(
            tabID: tabID,
            title: title,
            orderIndex: orderIndex,
            layout: layout,
            visibleLayout: visibleLayout,
            zoomed: zoomed,
            activePaneID: activePaneID
        )
    }

    @Test func layoutJSONRoundTripMatchesPluginFixture() throws {
        let json = """
        {"width":200,"height":50,"x":0,"y":0,"horizontal":[\
        {"width":100,"height":50,"x":0,"y":0,"pane":"w2:p1"},\
        {"width":99,"height":50,"x":101,"y":0,"pane":"w2:p2"}]}
        """
        let node = try JSONDecoder().decode(
            RemoteHerdrLayoutNode.self,
            from: Data(json.utf8)
        )
        #expect(node.paneIDsInOrder == ["w2:p1", "w2:p2"])
        let specs = node.splitSpecs
        #expect(specs.count == 1)
        #expect(specs[0].paneID == "w2:p2")
        #expect(specs[0].splitFromPaneID == "w2:p1")
        #expect(specs[0].direction == .right)
        let encoded = try JSONEncoder().encode(node)
        let again = try JSONDecoder().decode(RemoteHerdrLayoutNode.self, from: encoded)
        #expect(again.structureSignature == node.structureSignature)
    }

    @Test func firstApplyCreatesPanesAndSplitSpecs() {
        let (state, result) = RemoteHerdrWindowMirror.apply(
            window: window(layout: horizontalSplit(), activePaneID: "w2:p2"),
            previous: nil
        )
        #expect(result.createdPaneIDs == ["w2:p1", "w2:p2"])
        #expect(result.closedPaneIDs.isEmpty)
        #expect(result.structureChanged)
        #expect(result.focusPaneID == "w2:p2")
        #expect(result.splitSpecs.count == 1)
        #expect(result.splitSpecs[0].paneID == "w2:p2")
        #expect(state.layoutStructureVersion == 0)
    }

    @Test func gonePaneClosesSurface() {
        var (state, _) = RemoteHerdrWindowMirror.apply(
            window: window(layout: horizontalSplit()),
            previous: nil
        )
        RemoteHerdrWindowMirror.bindSurface(
            paneID: "w2:p1",
            surfaceID: UUID(),
            state: &state
        )
        RemoteHerdrWindowMirror.bindSurface(
            paneID: "w2:p2",
            surfaceID: UUID(),
            state: &state
        )
        let (state2, result) = RemoteHerdrWindowMirror.apply(
            window: window(layout: leaf("w2:p1")),
            previous: state
        )
        #expect(result.closedPaneIDs == ["w2:p2"])
        #expect(result.keptPaneIDs == ["w2:p1"])
        #expect(state2.surfaceIDByPaneID["w2:p2"] == nil)
        #expect(state2.layoutStructureVersion == 1)
    }

    @Test func zoomKeepsHiddenPaneIDs() {
        let (state, _) = RemoteHerdrWindowMirror.apply(
            window: window(layout: horizontalSplit()),
            previous: nil
        )
        let zoomed = window(
            layout: horizontalSplit(),
            zoomed: true,
            visibleLayout: leaf("w2:p2", width: 200, height: 50),
            activePaneID: "w2:p2"
        )
        let (state2, result) = RemoteHerdrWindowMirror.apply(
            window: zoomed,
            previous: state
        )
        #expect(result.createdPaneIDs.isEmpty)
        #expect(result.closedPaneIDs.isEmpty)
        #expect(state2.paneIDs == ["w2:p1", "w2:p2"])
        #expect(result.renderedLayout.paneIDsInOrder == ["w2:p2"])
        #expect(!result.structureChanged)
        #expect(state2.layoutStructureVersion == state.layoutStructureVersion)
    }

    @Test func geometryOnlyDoesNotBumpStructureVersion() {
        let (state, _) = RemoteHerdrWindowMirror.apply(
            window: window(layout: horizontalSplit()),
            previous: nil
        )
        let wider = RemoteHerdrLayoutNode(
            width: 400,
            height: 50,
            x: 0,
            y: 0,
            content: .horizontal([
                leaf("w2:p1", width: 200, height: 50, x: 0, y: 0),
                leaf("w2:p2", width: 199, height: 50, x: 201, y: 0),
            ])
        )
        let (state2, result) = RemoteHerdrWindowMirror.apply(
            window: window(layout: wider),
            previous: state
        )
        #expect(!result.structureChanged)
        #expect(state2.layoutStructureVersion == state.layoutStructureVersion)
        #expect(result.createdPaneIDs.isEmpty)
        #expect(result.closedPaneIDs.isEmpty)
    }

    @Test func sessionOrderFollowsTabNumbers() {
        let windows = [
            window(layout: leaf("p-b"), tabID: "t2", orderIndex: 2),
            window(layout: leaf("p-a"), tabID: "t1", orderIndex: 1),
        ]
        let result = RemoteHerdrSessionMirror.reconcile(
            windows: windows,
            previousTabIDs: []
        )
        #expect(result.orderedTabIDs == ["t1", "t2"])
        #expect(result.createdTabIDs == ["t1", "t2"])
        #expect(!result.orderChanged)
    }

    @Test func sessionReorderSetsOrderChanged() {
        let windows = [
            window(layout: leaf("p-a"), tabID: "t1", orderIndex: 0),
            window(layout: leaf("p-b"), tabID: "t2", orderIndex: 1),
        ]
        let result = RemoteHerdrSessionMirror.reconcile(
            windows: windows,
            previousTabIDs: ["t2", "t1"]
        )
        #expect(result.orderChanged)
        #expect(result.keptTabIDs == ["t1", "t2"])
        #expect(result.createdTabIDs.isEmpty)
    }

    @Test func windowsFromSnapshotUseLayoutsAndFocus() {
        let tree = NestedTopologyFixtures.baseTree()
        let pane2 = NestedPaneNode(
            id: NestedTopologyFixtures.nodeID(kind: .pane, rawID: "w1:p2"),
            tabID: tree.tab.id,
            displayTitle: "Pane 2",
            orderIndex: 1
        )
        let snapshot = NestedTopologyFixtures.snapshot(
            panes: [tree.pane, pane2],
            focus: NestedFocus(
                workspaceID: tree.workspace.id,
                tabID: tree.tab.id,
                paneID: pane2.id
            )
        )
        let layout = horizontalSplit()
        let windows = RemoteHerdrSessionMirror.windows(
            from: snapshot,
            layouts: [tree.tab.id.rawID: layout]
        )
        #expect(windows.count == 1)
        #expect(windows[0].activePaneID == "w1:p2")
        #expect(windows[0].layout.paneIDsInOrder == ["w2:p1", "w2:p2"])
    }

    @Test func clientGridIndependentOfPaneFrames() {
        let grid = RemoteHerdrSizing().clientGrid(
            contentWidth: 800,
            contentHeight: 400,
            cellWidth: 8,
            cellHeight: 16
        )
        #expect(grid?.cols == 100)
        #expect(grid?.rows == 25)
        let withChrome = RemoteHerdrSizing().clientGrid(
            contentWidth: 800,
            contentHeight: 400,
            cellWidth: 8,
            cellHeight: 16,
            chromeWidth: 16,
            chromeHeight: 32
        )
        #expect(withChrome?.cols == 98)
        #expect(withChrome?.rows == 23)
        #expect(
            RemoteHerdrSizing().clientGrid(
                contentWidth: 10,
                contentHeight: 10,
                cellWidth: 0,
                cellHeight: 16
            ) == nil
        )
        #expect(RemoteHerdrSizing().resizeCells(draggedExtent: 400, axisSpan: 800, totalCells: 100) == 50)
        #expect(RemoteHerdrSizing().resizeCells(draggedExtent: 0, axisSpan: 800, totalCells: 100) == 5)
        #expect(RemoteHerdrSizing().resizeCells(draggedExtent: 800, axisSpan: 800, totalCells: 100) == 95)
        #expect(RemoteHerdrSizing().resizeCells(draggedExtent: 400, axisSpan: 800, totalCells: 1) == 1)
    }

    @Test func outputDeltaIncrementalAndRedraw() {
        let first = RemoteHerdrOutput.delta(previous: nil, current: "hello")
        #expect(first.0.chunk == "hello")
        #expect(first.0.fullRedraw)
        let append = RemoteHerdrOutput.delta(previous: "hello", current: "hello\nworld")
        #expect(append.0.chunk == "\nworld")
        #expect(!append.0.fullRedraw)
        let same = RemoteHerdrOutput.delta(previous: "hello", current: "hello")
        #expect(same.0.chunk.isEmpty)
        let redraw = RemoteHerdrOutput.delta(previous: "hello", current: "goodbye")
        #expect(redraw.0.chunk == "goodbye")
        #expect(redraw.0.fullRedraw)
    }

    @Test func publicCapabilityAdvertisesWindowMirror() {
        #expect(
            NestedTopologyPublicCapability.windowMirrorV1.rawValue
                == "nested_topology.window_mirror.v1"
        )
        #expect(HerdrProtocol17Compatibility.mirrorCapabilities.contains(.paneResizeV1))
        #expect(HerdrProtocol17Compatibility.mirrorCapabilities.contains(.paneReadV1))
    }
}

@Suite struct RemoteHerdrPaneIOTests {
    @Test func sendAndReadRoundTrip() async throws {
        let server = try FakeHerdrUnixSocketServer { _, id, method in
            switch method {
            case "pane.send":
                return [HerdrFakeFixtures.line(HerdrFakeFixtures.focusOKJSON(id: id))]
            case "pane.read":
                let json =
                    "{\"id\":\"\(id)\",\"result\":{\"type\":\"pane_text\",\"text\":\"hello\"}}"
                return [HerdrFakeFixtures.line(json)]
            case "pane.split", "pane.resize", "pane.close":
                return [HerdrFakeFixtures.line(HerdrFakeFixtures.focusOKJSON(id: id))]
            default:
                return [HerdrFakeFixtures.line(HerdrFakeFixtures.errorJSON(id: id))]
            }
        }
        defer { server.shutdown() }

        let client = HerdrNestedTopologyClient(
            configuration: HerdrNestedTopologyClientConfiguration(
                socketPath: server.path,
                attachmentID: HerdrFakeFixtures.attachmentID,
                hostStableSurfaceID: HerdrFakeFixtures.hostSurfaceID,
                connectTimeout: .seconds(2),
                requestTimeout: .seconds(2)
            )
        )
        try await client.sendKeys(paneID: "w1:p1", data: Data("x".utf8))
        try await client.splitPane(paneID: "w1:p1", direction: .right)
        try await client.resizePane(paneID: "w1:p1", cols: 80, rows: 24)
        try await client.closePane(paneID: "w1:p1")
        let data = try await client.readPane(paneID: "w1:p1", lines: 20)
        #expect(String(decoding: data, as: UTF8.self) == "hello")
    }

    @Test func snapshotDecodesLayoutsMap() throws {
        let json = """
        {"id":"req","result":{"type":"session_snapshot","snapshot":{\
        "version":"0.7.0","protocol":17,\
        "focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":"w1:p1",\
        "workspaces":[{"workspace_id":"w1","number":1,"label":"Main"}],\
        "tabs":[{"tab_id":"w1:t1","workspace_id":"w1","number":1,"label":"Build"}],\
        "panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","label":"p"}],\
        "layouts":{"w1:t1":{"width":80,"height":24,"x":0,"y":0,"pane":"w1:p1"}},\
        "agents":[]}}}
        """
        let response = try HerdrProtocol17Compatibility().decodeResponseLine(
            json,
            expectedRequestID: HerdrJSONRPCRequestID(rawValue: "req")
        )
        guard let result = response.result, case .sessionSnapshot(let wire) = result else {
            Issue.record("expected snapshot")
            return
        }
        #expect(wire.layouts["w1:t1"]?.paneIDsInOrder == ["w1:p1"])
    }
}
