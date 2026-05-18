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
            toolInputJSON: #"{"description":"Explore settings","subagent_type":"explorer","subagent_model":"child-sonnet","prompt":"Map settings code paths"}"#,
            extraFieldsJSON: #"{"model":"parent-opus"}"#
        ))

        let graph = WorkstreamAgentGraphBuilder.snapshot(from: store.items)
        #expect(graph.nodeCount == 2)
        #expect(graph.edgeCount == 1)
        #expect(graph.roots.count == 1)
        let parent = graph.roots.first
        #expect(parent?.model == "parent-opus")
        #expect(parent?.subagentType == nil)
        #expect(parent?.taskDescription == nil)
        let child = graph.roots.first?.children.first
        #expect(child?.kind == .spawnRequest)
        #expect(child?.subagentType == "explorer")
        #expect(child?.model == "child-sonnet")
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

    @Test("Sanitized extra prompt metadata supplies graph task description")
    func sanitizedExtraPromptMetadataSuppliesGraphTaskDescription() throws {
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(WorkstreamEvent(
            sessionId: "claude-parent",
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: "workspace-1"
        ))
        store.ingest(WorkstreamEvent(
            sessionId: "claude-child",
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: "workspace-1",
            extraFieldsJSON: #"{"parent_workstream_id":"claude-parent","prompt":"Map settings code paths","secret":"do not persist"}"#
        ))

        let extraData = try #require(store.items.last?.extraFieldsJSON?.data(using: .utf8))
        let extra = try #require(
            try JSONSerialization.jsonObject(with: extraData) as? [String: Any]
        )
        #expect(extra["prompt"] as? String == "Map settings code paths")
        #expect(extra["secret"] == nil)

        let graph = WorkstreamAgentGraphBuilder.snapshot(from: store.items)
        let child = graph.roots.first?.children.first
        #expect(child?.workstreamId == "claude-child")
        #expect(child?.taskDescription == "Map settings code paths")
    }

    @Test("Session metadata on non-tool events appears on root nodes")
    func sessionMetadataOnNonToolEventsAppearsOnRootNodes() {
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(WorkstreamEvent(
            sessionId: "claude-root",
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: "workspace-1",
            extraFieldsJSON: #"{"description":"Coordinate rollout","subagent_type":"planner","model":"sonnet"}"#
        ))

        let graph = WorkstreamAgentGraphBuilder.snapshot(from: store.items)
        #expect(graph.nodeCount == 1)
        let root = graph.roots.first
        #expect(root?.workstreamId == "claude-root")
        #expect(root?.title == "Coordinate rollout")
        #expect(root?.subagentType == "planner")
        #expect(root?.model == "sonnet")
        #expect(root?.taskDescription == nil)
    }

    @Test("Description-only spawn metadata is not duplicated as task text")
    func descriptionOnlySpawnMetadataDoesNotDuplicateTaskText() {
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(WorkstreamEvent(
            sessionId: "claude-parent",
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: "workspace-1"
        ))
        store.ingest(WorkstreamEvent(
            sessionId: "claude-parent",
            hookEventName: .preToolUse,
            source: "claude",
            workspaceId: "workspace-1",
            toolName: "Task",
            toolInputJSON: #"{"description":"Explore settings","subagent_type":"explorer"}"#
        ))

        let graph = WorkstreamAgentGraphBuilder.snapshot(from: store.items)
        let child = graph.roots.first?.children.first
        #expect(child?.kind == .spawnRequest)
        #expect(child?.title == "Explore settings")
        #expect(child?.taskDescription == nil)
    }

    @Test("Non-spawn tool input does not create graph metadata")
    func nonSpawnToolInputDoesNotCreateGraphMetadata() {
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(WorkstreamEvent(
            sessionId: "claude-parent",
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: "workspace-1"
        ))
        store.ingest(WorkstreamEvent(
            sessionId: "claude-child",
            hookEventName: .preToolUse,
            source: "claude",
            workspaceId: "workspace-1",
            toolName: "Read",
            toolInputJSON: #"{"parent_workstream_id":"claude-parent","file_path":"/tmp/notes.json"}"#
        ))

        let graph = WorkstreamAgentGraphBuilder.snapshot(from: store.items)
        #expect(graph.nodeCount == 2)
        #expect(graph.edgeCount == 0)
        #expect(graph.roots.map(\.workstreamId).sorted() == ["claude-child", "claude-parent"])
    }

    @Test("Explicit child session prunes matching pending spawn")
    func explicitChildSessionPrunesMatchingPendingSpawn() {
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(WorkstreamEvent(
            sessionId: "claude-parent",
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: "workspace-1"
        ))
        store.ingest(WorkstreamEvent(
            sessionId: "claude-parent",
            hookEventName: .preToolUse,
            source: "claude",
            workspaceId: "workspace-1",
            toolName: "Task",
            toolInputJSON: #"{"description":"Explore settings","subagent_type":"explorer","prompt":"Map settings code paths"}"#
        ))
        store.ingest(WorkstreamEvent(
            sessionId: "claude-child",
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: "workspace-1",
            extraFieldsJSON: #"{"parent_workstream_id":"claude-parent","subagent_type":"explorer"}"#
        ))

        let graph = WorkstreamAgentGraphBuilder.snapshot(from: store.items)
        #expect(graph.nodeCount == 2)
        #expect(graph.edgeCount == 1)
        let child = graph.roots.first?.children.first
        #expect(child?.kind == .session)
        #expect(child?.workstreamId == "claude-child")
    }

    @Test("Explicit child session before spawn suppresses duplicate pending spawn")
    func explicitChildSessionBeforeSpawnSuppressesDuplicatePendingSpawn() {
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(WorkstreamEvent(
            sessionId: "claude-parent",
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: "workspace-1"
        ))
        store.ingest(WorkstreamEvent(
            sessionId: "claude-child",
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: "workspace-1",
            extraFieldsJSON: #"{"parent_workstream_id":"claude-parent","subagent_type":"explorer"}"#
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
        let children = graph.roots.first?.children ?? []
        #expect(children.map(\.kind) == [.session])
        #expect(children.map(\.workstreamId) == ["claude-child"])
    }

    @Test("Metadata-light child before spawn suppresses duplicate pending spawn")
    func metadataLightChildBeforeSpawnSuppressesDuplicatePendingSpawn() {
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(WorkstreamEvent(
            sessionId: "claude-parent",
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: "workspace-1"
        ))
        store.ingest(WorkstreamEvent(
            sessionId: "claude-child",
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: "workspace-1",
            extraFieldsJSON: #"{"parent_workstream_id":"claude-parent"}"#
        ))
        store.ingest(WorkstreamEvent(
            sessionId: "claude-parent",
            hookEventName: .preToolUse,
            source: "claude",
            workspaceId: "workspace-1",
            toolName: "Task",
            toolInputJSON: #"{}"#
        ))

        let graph = WorkstreamAgentGraphBuilder.snapshot(from: store.items)
        #expect(graph.nodeCount == 2)
        #expect(graph.edgeCount == 1)
        let children = graph.roots.first?.children ?? []
        #expect(children.map(\.kind) == [.session])
        #expect(children.map(\.workstreamId) == ["claude-child"])
    }

    @Test("Ambiguous child matches before spawn keep pending spawn")
    func ambiguousChildMatchesBeforeSpawnKeepPendingSpawn() {
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(WorkstreamEvent(
            sessionId: "claude-parent",
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: "workspace-1"
        ))
        store.ingest(WorkstreamEvent(
            sessionId: "claude-child-type",
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: "workspace-1",
            extraFieldsJSON: #"{"parent_workstream_id":"claude-parent","subagent_type":"explorer"}"#
        ))
        store.ingest(WorkstreamEvent(
            sessionId: "claude-child-task",
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: "workspace-1",
            extraFieldsJSON: #"{"parent_workstream_id":"claude-parent","task_description":"Map settings code paths"}"#
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
        #expect(graph.nodeCount == 4)
        #expect(graph.edgeCount == 3)
        let children = graph.roots.first?.children ?? []
        #expect(children.filter { $0.kind == .session }.count == 2)
        #expect(children.filter { $0.kind == .spawnRequest }.count == 1)
    }

    @Test("Parent child metadata prunes matching pending spawn")
    func parentChildMetadataPrunesMatchingPendingSpawn() {
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(WorkstreamEvent(
            sessionId: "claude-parent",
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: "workspace-1"
        ))
        store.ingest(WorkstreamEvent(
            sessionId: "claude-parent",
            hookEventName: .preToolUse,
            source: "claude",
            workspaceId: "workspace-1",
            toolName: "Task",
            toolInputJSON: #"{"description":"Explore settings","subagent_type":"explorer","prompt":"Map settings code paths"}"#
        ))
        store.ingest(WorkstreamEvent(
            sessionId: "claude-parent",
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: "workspace-1",
            extraFieldsJSON: #"{"child_workstream_id":"claude-child","subagent_type":"explorer"}"#
        ))

        let graph = WorkstreamAgentGraphBuilder.snapshot(from: store.items)
        #expect(graph.nodeCount == 2)
        #expect(graph.edgeCount == 1)
        let child = graph.roots.first?.children.first
        #expect(child?.kind == .session)
        #expect(child?.workstreamId == "claude-child")
    }

    @Test("Explicit child without a unique metadata match keeps pending spawns")
    func explicitChildWithoutUniqueMetadataMatchKeepsPendingSpawns() {
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(WorkstreamEvent(
            sessionId: "claude-parent",
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: "workspace-1"
        ))
        store.ingest(WorkstreamEvent(
            sessionId: "claude-parent",
            hookEventName: .preToolUse,
            source: "claude",
            workspaceId: "workspace-1",
            toolName: "Task",
            toolInputJSON: #"{"description":"Explore settings","subagent_type":"explorer","prompt":"Map settings code paths"}"#
        ))
        store.ingest(WorkstreamEvent(
            sessionId: "claude-parent",
            hookEventName: .preToolUse,
            source: "claude",
            workspaceId: "workspace-1",
            toolName: "Task",
            toolInputJSON: #"{"description":"Audit theme","subagent_type":"auditor","prompt":"Audit theme code paths"}"#
        ))
        store.ingest(WorkstreamEvent(
            sessionId: "claude-child",
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: "workspace-1",
            extraFieldsJSON: #"{"parent_workstream_id":"claude-parent"}"#
        ))

        let graph = WorkstreamAgentGraphBuilder.snapshot(from: store.items)
        #expect(graph.nodeCount == 4)
        #expect(graph.edgeCount == 3)
        let children = graph.roots.first?.children ?? []
        #expect(children.filter { $0.kind == .session }.map(\.workstreamId) == ["claude-child"])
        #expect(children.filter { $0.kind == .spawnRequest }.count == 2)
    }
}
