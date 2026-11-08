import Foundation
import Testing
@testable import CmuxSurfaceCatalogModel

@Suite
struct CloudVMGraphCompletenessTests {
    private func state(detached: Bool = false, lifecycle: String = "running") throws -> CloudVMState {
        let names = ["a", "b"]
        let snapshot: [String: Any] = [
            "cursor": ["generation": "test", "revision": "1"],
            "workspaces": names.map { ["id": $0, "name": $0] },
            "screens": names.map { ["id": "screen_" + $0, "workspace_id": $0] },
            "panes": names.map { ["id": "pane_" + $0, "screen_id": "screen_" + $0] },
            "tabs": names.filter { !detached || $0 != "b" }.map {
                ["id": "tab_" + $0, "pane_id": "pane_" + $0,
                 "content_kind": "terminal", "content_id": "term_" + $0]
            },
            // Detached/exited terminal records may retain an old reverse tab
            // reference. The parser deliberately permits that wire format.
            "terminals": names.map {
                ["id": "term_" + $0, "tab_ids": ["tab_" + $0], "lifecycle": lifecycle] as [String: Any]
            },
            "browsers": [], "agents": []
        ]
        return try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: .cloud("complete-graph")))
    }

    @Test("Complete live placements admit reconciliation")
    func completeGraph() throws {
        let graph = try state()
        let completeness = CloudVMGraphCompleteness(state: graph, resources: CmuxTuiSnapshotParser.resources(from: graph))
        #expect(completeness.isComplete())
        #expect(completeness.isComplete(workspaceID: "a"))
        #expect(completeness.isComplete(workspaceID: "b"))
    }

    @Test("Incomplete resource joins block only the affected workspace", arguments: [
        "resource", "views", "tab", "workspace", "screen", "pane", "machine"
    ])
    func missingPlacement(field: String) throws {
        let graph = try state()
        var resources = CmuxTuiSnapshotParser.resources(from: graph)
        let index = try #require(resources.firstIndex { $0.id.key == "term_b" })
        switch field {
        case "resource": resources.remove(at: index)
        case "views": resources[index].remoteViews = []
        case "tab": resources[index].remoteViews?[0].tabID = "another-tab"
        case "workspace": resources[index].remoteViews?[0].workspace.id = "a"
        case "screen": resources[index].remoteViews?[0].screenID = "screen_a"
        case "pane": resources[index].remoteViews?[0].paneID = "pane_a"
        case "machine": resources[index].id = .init(machine: .cloud("other"), kind: .terminal, key: "term_b")
        default: Issue.record("Unexpected field")
        }
        let completeness = CloudVMGraphCompleteness(state: graph, resources: resources)
        #expect(!completeness.isComplete())
        #expect(completeness.isComplete(workspaceID: "a"))
        #expect(!completeness.isComplete(workspaceID: "b"))
    }

    @Test("Detached or exited terminals do not hold unrelated workspaces open", arguments: ["running", "exited"])
    func detachedReverseReference(lifecycle: String) throws {
        let graph = try state(detached: true, lifecycle: lifecycle)
        #expect(graph.lookupIndex.tab(id: "tab_b") == nil)
        #expect(graph.lookupIndex.terminal(id: "term_b")?.tabIDs == ["tab_b"])
        let completeness = CloudVMGraphCompleteness(state: graph, resources: CmuxTuiSnapshotParser.resources(from: graph))
        #expect(completeness.isComplete())
        #expect(completeness.isComplete(workspaceID: "b"))
    }

    @Test("Each live view of a shared terminal is required")
    func oneTerminalWithMultipleViews() throws {
        var snapshot = try #require(state().snapshotObject())
        var tabs = try #require(snapshot["tabs"] as? [[String: Any]])
        tabs[1]["content_id"] = "term_a"
        snapshot["tabs"] = tabs
        snapshot["terminals"] = [["id": "term_a", "lifecycle": "running"]]
        let graph = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: .cloud("complete-graph")))
        var resources = CmuxTuiSnapshotParser.resources(from: graph)
        try #require(resources.count == 1)
        #expect(CloudVMGraphCompleteness(state: graph, resources: resources).isComplete())
        resources[0].remoteViews?.removeAll { $0.workspace.id == "b" }
        let completeness = CloudVMGraphCompleteness(state: graph, resources: resources)
        #expect(completeness.isComplete(workspaceID: "a"))
        #expect(!completeness.isComplete(workspaceID: "b"))
    }
}
