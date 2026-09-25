import CmuxSurfaceCatalogModel
import Foundation
import Testing

struct CloudVMStateSnapshotComparisonTests {
    private func state(streamRevision: String, futureField: String? = nil) throws -> CloudVMState {
        var terminal: [String: Any] = [
            "id": "term-1",
            "title": "bash",
            "cwd": "/workspace",
            "lifecycle": "running",
            "stream_revision": streamRevision,
        ]
        if let futureField {
            terminal["future_field"] = futureField
        }
        return try #require(CmuxTuiSnapshotParser.state(fromSnapshot: [
            "cursor": ["generation": "daemon-1", "revision": "2"],
            "workspaces": [["id": "ws-1", "name": "Workspace"]],
            "screens": [],
            "panes": [],
            "tabs": [],
            "terminals": [terminal],
            "browsers": [],
            "agents": [],
        ], machine: .cloud("vm-test")))
    }

    @Test("Live terminal output revisions do not invalidate an equal-cursor graph")
    func terminalStreamRevisionDoesNotInvalidateGraph() throws {
        let before = try state(streamRevision: "7")
        let after = try state(streamRevision: "8")

        #expect(before != after, "The complete snapshots retain their live output metadata")
        #expect(before.hasSameRevisionedContent(as: after))

        let changed = try state(streamRevision: "8", futureField: "changed")
        #expect(!before.hasSameRevisionedContent(as: changed))
    }
}
