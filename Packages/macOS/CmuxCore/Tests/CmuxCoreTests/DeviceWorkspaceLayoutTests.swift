import CmuxCore
import Foundation
import Testing

@Suite("Mac device workspace layouts")
struct DeviceWorkspaceLayoutTests {
    @Test func nativeLayoutRoundTrip() throws {
        let tree = DeviceWorkspaceLayoutNode.split(direction: .horizontal, ratio: 0.65,
            first: .pane(id: "left", surfaceIDs: ["a", "b"], selectedSurfaceID: "b"),
            second: .split(direction: .vertical, ratio: 0.3,
                first: .pane(id: "top", surfaceIDs: ["c"], selectedSurfaceID: "c"),
                second: .pane(id: "bottom", surfaceIDs: ["d"], selectedSurfaceID: nil)))
        let snapshot = DeviceWorkspaceLayoutSnapshot(workspaceID: "workspace", layout: tree)
        let encoded = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(DeviceWorkspaceLayoutSnapshot.self, from: encoded) == snapshot)
    }

    @Test func decodesMacWireFormatWithoutMobileState() throws {
        let data = Data(#"{"workspace_id":"w1","layout":{"type":"pane","pane_id":"p1","surface_ids":["t2","t1"],"selected_surface_id":"t1"}}"#.utf8)
        let snapshot = try JSONDecoder().decode(DeviceWorkspaceLayoutSnapshot.self, from: data)
        #expect(snapshot.workspaceID == "w1")
        #expect(snapshot.layout == .pane(id: "p1", surfaceIDs: ["t2", "t1"], selectedSurfaceID: "t1"))
    }

    @Test func rejectsUnknownLayoutNodes() {
        let data = Data(#"{"workspace_id":"w1","layout":{"type":"unknown"}}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(DeviceWorkspaceLayoutSnapshot.self, from: data)
        }
    }
}
