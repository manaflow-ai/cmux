import CmuxNextOnboarding
import Foundation
import Testing

@Suite struct ClassicSessionSecurityTests {
    @Test func aSnapshotWithTooManyWorkspacesIsRejected() throws {
        let workspace: [String: Any] = ["currentDirectory": "/tmp", "panels": []]
        let data = try JSONSerialization.data(withJSONObject: [
            "windows": [["tabManager": ["workspaces": Array(repeating: workspace, count: 1_001)]]]
        ])
        #expect(rejected(data))
    }

    @Test func aSnapshotAtSupportedWorkspaceScaleDecodes() throws {
        let workspaces: [[String: Any]] = (0..<1_000).map { index in
            ["stableId": "workspace-\(index)", "currentDirectory": "/tmp/\(index)", "panels": []]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "windows": [["tabManager": ["workspaces": workspaces]]]
        ])
        let snapshot = try ClassicSessionImporter(fileURL: URL(fileURLWithPath: "/dev/null"))
            .decodeSnapshot(data)
        #expect(snapshot.workspaces.count == 1_000)
    }

    @Test func aSnapshotWithADeepLayoutIsRejected() throws {
        let pane: [String: Any] = ["type": "pane", "pane": ["panelIds": []]]
        var layout = pane
        for _ in 0..<65 {
            layout = ["type": "split", "split": ["first": layout, "second": pane]]
        }
        let data = try snapshot(workspace: ["currentDirectory": "/tmp", "panels": [], "layout": layout])
        #expect(rejected(data))
    }

    @Test func aSnapshotWithOversizedScrollbackIsRejected() throws {
        let panel: [String: Any] = [
            "id": "terminal", "type": "terminal",
            "terminal": ["scrollback": String(repeating: "x", count: 4 * 1024 * 1024 + 1)]
        ]
        let layout: [String: Any] = ["type": "pane", "pane": ["panelIds": ["terminal"]]]
        let data = try snapshot(workspace: ["currentDirectory": "/tmp", "panels": [panel], "layout": layout])
        #expect(rejected(data))
    }

    @Test func aSnapshotWithAnOversizedMetadataKeyIsRejected() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "windows": [],
            String(repeating: "k", count: 64 * 1024 + 1): true,
        ])
        #expect(rejected(data))
    }

    private func rejected(_ data: Data) -> Bool {
        do {
            _ = try ClassicSessionImporter(fileURL: URL(fileURLWithPath: "/dev/null")).decode(data)
            return false
        } catch {
            return true
        }
    }

    private func snapshot(workspace: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "windows": [["tabManager": ["workspaces": [workspace]]]]
        ])
    }
}
