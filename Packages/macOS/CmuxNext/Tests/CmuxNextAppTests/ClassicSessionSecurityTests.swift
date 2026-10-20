import CmuxNextOnboarding
import Foundation
import Testing

@Suite struct ClassicSessionSecurityTests {
    @Test func aSnapshotWithTooManyWorkspacesIsRejected() throws {
        let workspace: [String: Any] = ["currentDirectory": "/tmp", "panels": []]
        let data = try JSONSerialization.data(withJSONObject: [
            "windows": [["tabManager": ["workspaces": Array(repeating: workspace, count: 129)]]]
        ])
        #expect(rejected(data))
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
