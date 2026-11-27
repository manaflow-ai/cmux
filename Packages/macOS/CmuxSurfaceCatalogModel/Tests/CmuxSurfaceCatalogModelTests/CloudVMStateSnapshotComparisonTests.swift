import CmuxSurfaceCatalogModel
import Foundation
import Testing

struct CloudVMStateSnapshotComparisonTests {
    /// Builds a versioned graph whose terminal has live output metadata.
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

    /// Keeps terminal stream observations out of equal-cursor conflict checks.
    @Test("Live terminal output revisions do not invalidate an equal-cursor graph")
    func terminalStreamRevisionDoesNotInvalidateGraph() throws {
        let before = try state(streamRevision: "7")
        let after = try state(streamRevision: "8")

        #expect(before != after, "The complete snapshots retain their live output metadata")
        #expect(before.hasSameRevisionedContent(as: after))

        let changed = try state(streamRevision: "8", futureField: "changed")
        #expect(!before.hasSameRevisionedContent(as: changed))
    }

    /// Rows shared by the graph before and after a terminal exit detaches its
    /// only tab, pane, and screen.
    private func exitGraph(revision: String, attached: Bool, terminal: [String: Any]) -> [String: Any] {
        [
            "cursor": ["generation": "daemon-1", "revision": revision],
            "workspaces": [["id": "ws-1", "name": "Workspace", "index": 0, "focused": true]],
            "screens": attached ? [["id": "screen-1", "workspace_id": "ws-1", "index": 0]] : [],
            "panes": attached ? [["id": "pane-1", "screen_id": "screen-1"]] : [],
            "tabs": attached ? [[
                "id": "tab-1", "pane_id": "pane-1", "index": 0,
                "content_kind": "terminal", "content_id": "term-1",
            ]] : [],
            "terminals": [terminal],
            "browsers": [],
            "agents": [],
        ]
    }

    /// A terminal exit is one batch: the exited terminal row, written while its
    /// tab still existed, followed by deletes for that tab and its layout. The
    /// full snapshot at the same revision derives the terminal's tab edge from
    /// topology and reports it detached. Both describe the same graph.
    @Test("A terminal exit delta matches the full snapshot at the same revision")
    func terminalExitDeltaMatchesFullSnapshot() throws {
        let running: [String: Any] = [
            "id": "term-1", "tab_id": "tab-1", "tab_ids": ["tab-1"],
            "running": true, "lifecycle": "running", "title": "bash", "cols": 80, "rows": 24,
        ]
        let before = try #require(CmuxTuiSnapshotParser.state(
            fromSnapshot: exitGraph(revision: "22", attached: true, terminal: running),
            machine: .cloud("vm-test")
        ))
        let exit: [String: Any] = [
            "outcome": ["kind": "exit", "code": 0], "exited_at": "1790570877173", "revision": "23",
        ]
        var exitedRow = running
        exitedRow["running"] = false
        exitedRow["lifecycle"] = "exited"
        exitedRow["exit"] = exit
        let changes: [[String: Any]] = [
            ["kind": "upsert", "sequence": 0, "resource": "terminal", "id": "term-1", "value": exitedRow],
            ["kind": "delete", "sequence": 1, "resource": "tab", "id": "tab-1"],
            ["kind": "delete", "sequence": 2, "resource": "pane", "id": "pane-1"],
            ["kind": "delete", "sequence": 3, "resource": "screen", "id": "screen-1"],
        ]
        let payload = try JSONSerialization.data(withJSONObject: ["changes": changes])
        let cursor = CloudVMCursor(generation: "daemon-1", revision: 23)
        let fromDelta = try #require(CmuxTuiSnapshotParser.applying(
            deltaPayload: payload, cursor: cursor, to: before
        ))
        #expect(fromDelta.terminals.first?.tabIDs == [], "The typed graph detaches the deleted tab")

        var fullRow = exitedRow
        fullRow["tab_id"] = NSNull()
        fullRow["tab_ids"] = [String]()
        fullRow["title"] = ""
        let fullSnapshot = try #require(CmuxTuiSnapshotParser.state(
            fromSnapshot: exitGraph(revision: "23", attached: false, terminal: fullRow),
            machine: .cloud("vm-test")
        ))
        #expect(fromDelta.hasSameRevisionedContent(as: fullSnapshot))
        #expect(fullSnapshot.hasSameRevisionedContent(as: fromDelta))

        // The tab relation itself stays strict: a snapshot that places the
        // terminal in a different tab is a conflict at the same cursor.
        fullRow["tab_id"] = "tab-other"
        fullRow["tab_ids"] = ["tab-other"]
        let moved = try #require(CmuxTuiSnapshotParser.state(
            fromSnapshot: exitGraph(revision: "23", attached: false, terminal: fullRow),
            machine: .cloud("vm-test")
        ))
        #expect(!fromDelta.hasSameRevisionedContent(as: moved))

        // Other exit fields remain strict.
        fullRow["tab_id"] = NSNull()
        fullRow["tab_ids"] = [String]()
        fullRow["exit"] = ["outcome": ["kind": "exit", "code": 1], "exited_at": "1790570877173", "revision": "23"]
        let differentExit = try #require(CmuxTuiSnapshotParser.state(
            fromSnapshot: exitGraph(revision: "23", attached: false, terminal: fullRow),
            machine: .cloud("vm-test")
        ))
        #expect(!fromDelta.hasSameRevisionedContent(as: differentExit))
    }
}
