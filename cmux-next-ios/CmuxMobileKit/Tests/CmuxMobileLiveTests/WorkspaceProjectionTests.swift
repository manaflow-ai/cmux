import Foundation
import Testing
@testable import CmuxMobileLive

@Suite struct WorkspaceProjectionTests {
    private static let snapshot = Data(#"{"ok":true,"data":{"workspace_revision":1,"registry_id":"r","workspaces":[{"id":1,"key":"w1","name":"one","resource_id":"ws_1","screens":[{"id":2,"panes":[{"id":3,"tabs":[{"surface":4,"kind":"pty","title":"old"},{"surface":5,"kind":"pty","title":"hidden"}],"tab_groups":[{"id":"g1"}]}]}]}]}}"#.utf8)

    private static func entity(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    private static func delta(_ kind: DaemonTreeDelta.Kind, workspace: Int = 1, screen: Int? = 2, pane: Int? = 3,
                              surface: Int? = nil, index: Int? = nil, entity: [String: Any]? = nil,
                              revision: Int? = nil) -> DaemonEvent {
        .delta(DaemonTreeDelta(kind: kind, workspace: workspace, screen: screen, pane: pane, surface: surface,
                               index: index, entity: entity.map(Self.entity), workspaceRevision: revision, registryID: "r"))
    }

    @Test func duplicateTabAddIsIdempotentAndPreservesOrder() async throws {
        let projection = WorkspaceProjection()
        _ = try await projection.reset(snapshot: Self.snapshot, macID: "m")
        let tab: [String: Any] = ["surface": 6, "kind": "pty", "title": "new"]
        let add = Self.delta(.tabAdded, surface: 6, index: 1, entity: tab)
        let first = try await projection.apply(add, agents: AgentStates(), activity: [:])
        let second = try await projection.apply(add, agents: AgentStates(), activity: [:])
        #expect(first?.tree.workspaces[0].tabs.map(\.id) == ["s4", "s6", "s5"])
        #expect(second == nil)
    }

    @Test func duplicateCloseAndUnknownRenameRequestSnapshot() async throws {
        let projection = WorkspaceProjection()
        _ = try await projection.reset(snapshot: Self.snapshot, macID: "m")
        let close = Self.delta(.tabClosed, surface: 5)
        _ = try await projection.apply(close, agents: AgentStates(), activity: [:])
        #expect(try await projection.apply(close, agents: AgentStates(), activity: [:]) == nil)
        let rename = Self.delta(.tabRenamed, surface: 99, entity: ["surface": 99, "kind": "pty", "title": "bad"])
        #expect(throws: WorkspaceProjection.ProjectionError.needsSnapshot) {
            try await projection.apply(rename, agents: AgentStates(), activity: [:])
        }
    }

    @Test func revisionGapDoesNotPartiallyApplyAndHiddenMetadataIsRemoved() async throws {
        let projection = WorkspaceProjection()
        _ = try await projection.reset(snapshot: Self.snapshot, macID: "m")
        let gap = Self.delta(.workspaceChanged, entity: ["id": 1, "key": "w1", "name": "gap", "screens": []], revision: 3)
        #expect(throws: WorkspaceProjection.ProjectionError.needsSnapshot) {
            try await projection.apply(gap, agents: AgentStates(), activity: [:])
        }
        let close = Self.delta(.workspaceClosed, revision: 2)
        let update = try await projection.apply(close, agents: AgentStates(), activity: [:])
        #expect(update?.tree.workspaces.isEmpty == true)
        #expect(update?.tree.surfaces["s5"] == nil)
    }

    @Test func titleUpdateKeepsWorkspaceOrder() async throws {
        let snapshot = Data(#"{"ok":true,"data":{"workspace_revision":1,"workspaces":[{"id":1,"key":"a","name":"a","screens":[]},{"id":2,"key":"b","name":"b","screens":[]}]}}"#.utf8)
        let projection = WorkspaceProjection()
        _ = try await projection.reset(snapshot: snapshot, macID: "m")
        let title = Self.delta(.workspaceRenamed, workspace: 2, screen: nil, pane: nil,
                               entity: ["id": 2, "key": "b", "name": "renamed", "screens": []], revision: 2)
        let update = try await projection.apply(title, agents: AgentStates(), activity: [:])
        #expect(update?.tree.workspaces.map(\.id) == ["a", "b"])
    }
}
