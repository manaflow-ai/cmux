import CmuxCore
import Foundation
import Testing

@Suite("Mac device workspace layouts")
struct DeviceWorkspaceLayoutTests {
    @Test func arrangementComparisonIgnoresLocalPaneIdentitiesAndSelection() {
        let source = DeviceWorkspaceLayoutNode.pane(id: "source-pane", surfaceIDs: ["a", "b"], selectedSurfaceID: "a")
        let viewer = DeviceWorkspaceLayoutNode.pane(id: "viewer-pane", surfaceIDs: ["a", "b"], selectedSurfaceID: "b")
        #expect(source.hasSameArrangement(as: viewer))
        #expect(!source.hasSameArrangement(as: .pane(id: "source-pane", surfaceIDs: ["b", "a"], selectedSurfaceID: "a")))
    }

    @Test func mapsViewerPanelsToSourceTerminalsWithoutLosingOrder() throws {
        let local = DeviceWorkspaceLayoutNode.split(direction: .vertical, ratio: 0.4,
            first: .pane(id: "p1", surfaceIDs: ["local-a", "local-b"], selectedSurfaceID: "local-b"),
            second: .pane(id: "p2", surfaceIDs: ["local-c"], selectedSurfaceID: nil))
        let mapped = try local.remappingSurfaceIDs(["local-a": "a", "local-b": "b", "local-c": "c"])
        #expect(try mapped.validatedSurfaceIDs() == ["a", "b", "c"])
        guard case .split(_, let ratio, .pane(_, let ids, let selected), _) = mapped else {
            Issue.record("Expected the same split tree"); return
        }
        #expect(ratio == 0.4)
        #expect(ids == ["a", "b"])
        #expect(selected == "b")
        #expect(throws: (any Error).self) { try local.remappingSurfaceIDs(["local-a": "a"]) }
    }

    @Test func rejectsAmbiguousAndUnboundedLayoutWrites() {
        let a = DeviceWorkspaceLayoutNode.pane(id: "p", surfaceIDs: ["a"], selectedSurfaceID: "a")
        let invalid: [DeviceWorkspaceLayoutNode] = [
            .pane(id: "p", surfaceIDs: [], selectedSurfaceID: nil),
            .pane(id: "p", surfaceIDs: ["a", "a"], selectedSurfaceID: "a"),
            .pane(id: "p", surfaceIDs: ["a"], selectedSurfaceID: "other"),
            .split(direction: .horizontal, ratio: .nan, first: a, second: a),
            .split(direction: .horizontal, ratio: 1.2, first: a, second: a)
        ]
        for layout in invalid {
            #expect(throws: (any Error).self) { try layout.validatedSurfaceIDs() }
        }
        #expect(throws: (any Error).self) { try a.validatedSurfaceIDs(maximumSurfaceCount: 0) }
    }

    @Test func nativeLayoutRoundTrip() throws {
        let tree = DeviceWorkspaceLayoutNode.split(direction: .horizontal, ratio: 0.65,
            first: .pane(id: "left", surfaceIDs: ["a", "b"], selectedSurfaceID: "b"),
            second: .split(direction: .vertical, ratio: 0.3,
                first: .pane(id: "top", surfaceIDs: ["c"], selectedSurfaceID: "c"),
                second: .pane(id: "bottom", surfaceIDs: ["d"], selectedSurfaceID: nil)))
        let snapshot = DeviceWorkspaceLayoutSnapshot(workspaceID: "workspace", layout: tree, revision: "accepted-edit")
        let encoded = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(DeviceWorkspaceLayoutSnapshot.self, from: encoded) == snapshot)
    }

    @Test func decodesMacWireFormatWithoutMobileState() throws {
        let data = Data(#"{"workspace_id":"w1","layout":{"type":"pane","pane_id":"p1","surface_ids":["t2","t1"],"selected_surface_id":"t1"}}"#.utf8)
        let snapshot = try JSONDecoder().decode(DeviceWorkspaceLayoutSnapshot.self, from: data)
        #expect(snapshot.workspaceID == "w1")
        #expect(snapshot.revision.isEmpty)
        #expect(snapshot.layout == .pane(id: "p1", surfaceIDs: ["t2", "t1"], selectedSurfaceID: "t1"))
    }

    @Test func rejectsUnknownLayoutNodes() {
        let data = Data(#"{"workspace_id":"w1","layout":{"type":"unknown"}}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(DeviceWorkspaceLayoutSnapshot.self, from: data)
        }
    }
}
