import Foundation
import Testing
@testable import CMUXWorkstream

@MainActor
@Suite("WorkstreamAgentGraph")
struct WorkstreamAgentGraphTests {
    @Test("Task tool telemetry appears as a child spawn request")
    func taskToolCreatesSpawnRequestNode() {
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(WorkstreamEvent(
            sessionId: "claude-parent",
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: "workspace-1",
            cwd: "/tmp/project"
        ))
        store.ingest(WorkstreamEvent(
            sessionId: "claude-parent",
            hookEventName: .preToolUse,
            source: "claude",
            workspaceId: "workspace-1",
            toolName: "Task",
            toolInputJSON: #"{"description":"Explore settings","subagent_type":"explorer","prompt":"Map settings code paths"}"#
        ))

        let graph = WorkstreamAgentGraphBuilder.snapshot(from: store.items)
        #expect(graph.nodeCount == 2)
        #expect(graph.edgeCount == 1)
        #expect(graph.roots.count == 1)
        let child = graph.roots.first?.children.first
        #expect(child?.kind == .spawnRequest)
        #expect(child?.subagentType == "explorer")
        #expect(child?.taskDescription == "Map settings code paths")
        #expect(child?.focusWorkstreamId == "claude-parent")
    }

    @Test("Explicit parent metadata links a child session under its parent")
    func explicitParentMetadataLinksChildSession() {
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(WorkstreamEvent(
            sessionId: "claude-parent",
            hookEventName: .userPromptSubmit,
            source: "claude",
            workspaceId: "workspace-1",
            toolInputJSON: #"{"prompt":"coordinate the rollout"}"#
        ))
        store.ingest(WorkstreamEvent(
            sessionId: "claude-child",
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: "workspace-1",
            extraFieldsJSON: #"{"parent_workstream_id":"claude-parent","subagent_type":"planner","model":"sonnet"}"#
        ))

        let graph = WorkstreamAgentGraphBuilder.snapshot(from: store.items)
        #expect(graph.nodeCount == 2)
        #expect(graph.edgeCount == 1)
        #expect(graph.maxDepth == 1)
        #expect(graph.roots.map(\.workstreamId) == ["claude-parent"])
        let child = graph.roots.first?.children.first
        #expect(child?.workstreamId == "claude-child")
        #expect(child?.subagentType == "planner")
        #expect(child?.model == "sonnet")
        #expect(child?.focusWorkstreamId == "claude-child")
    }
}
