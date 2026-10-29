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

    @Test func applyingDeltaWithoutBaselineRequestsSnapshot() async throws {
        let projection = WorkspaceProjection()
        let add = Self.delta(.workspaceAdded, entity: ["id": 1, "key": "w1", "name": "one", "screens": []])
        await #expect(throws: WorkspaceProjection.ProjectionError.needsSnapshot) {
            try await projection.apply(add, agents: AgentStates(), activity: [:])
        }
        await #expect(throws: WorkspaceProjection.ProjectionError.needsSnapshot) {
            try await projection.apply(.titleChanged(surface: 4, title: "new"), agents: AgentStates(), activity: [:])
        }
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
        let first = try await projection.apply(close, agents: AgentStates(), activity: [:])
        #expect(first?.tree.surfaces["s5"] == nil)
        #expect(try await projection.apply(close, agents: AgentStates(), activity: [:]) == nil)
        let rename = Self.delta(.tabRenamed, surface: 99, entity: ["surface": 99, "kind": "pty", "title": "bad"])
        await #expect(throws: WorkspaceProjection.ProjectionError.needsSnapshot) {
            try await projection.apply(rename, agents: AgentStates(), activity: [:])
        }
    }

    @Test func nestedRenameIsMetadataOnly() async throws {
        let projection = WorkspaceProjection()
        _ = try await projection.reset(snapshot: Self.snapshot, macID: "m")
        let rename = Self.delta(.tabRenamed, surface: 4,
                                entity: ["surface": 4, "kind": "pty", "title": "renamed"])
        let update = try await projection.apply(rename, agents: AgentStates(), activity: [:])
        #expect(update?.topology == false)
        #expect(update?.tree.workspaces.first?.tabs.first?.title == "renamed")
    }

    @Test func workspaceInsertReindexesDisplacedSurfaces() async throws {
        let snapshot = Data(#"{"ok":true,"data":{"workspace_revision":1,"workspaces":[{"id":1,"key":"one","screens":[{"id":1,"panes":[{"id":1,"tabs":[{"surface":4,"kind":"pty","title":"one"}]}]}]},{"id":2,"key":"two","screens":[{"id":2,"panes":[{"id":2,"tabs":[{"surface":5,"kind":"pty","title":"two"}]}]}]}]}}"#.utf8)
        let projection = WorkspaceProjection()
        _ = try await projection.reset(snapshot: snapshot, macID: "m")
        let added: [String: Any] = ["id": 3, "key": "three", "screens": [["id": 3, "panes": [["id": 3, "tabs": [["surface": 6, "kind": "pty", "title": "three"]]]]]]
        _ = try await projection.apply(Self.delta(.workspaceAdded, workspace: 3, screen: nil, pane: nil, index: 0, entity: added), agents: AgentStates(), activity: [:])
        let update = try await projection.apply(.titleChanged(surface: 5, title: "updated"), agents: AgentStates(), activity: [:])
        #expect(update?.tree.workspaces.map(\.id) == ["three", "one", "two"])
        #expect(update?.tree.workspaces.first(where: { $0.id == "two" })?.tabs.first?.title == "updated")
    }

    @Test func revisionGapDoesNotPartiallyApplyAndHiddenMetadataIsRemoved() async throws {
        let projection = WorkspaceProjection()
        _ = try await projection.reset(snapshot: Self.snapshot, macID: "m")
        let gap = Self.delta(.workspaceChanged, entity: ["id": 1, "key": "w1", "name": "gap", "screens": []], revision: 3)
        await #expect(throws: WorkspaceProjection.ProjectionError.needsSnapshot) {
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
