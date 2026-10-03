import Foundation
import Testing
@testable import CmuxNextDaemon

/// The manual workspace unread mark (`notification-mark-unread-v1`):
/// `marked_unread` on `set-workspace-metadata` and on every workspace entity.
@MainActor struct WorkspaceMarkUnreadTests {
    private func object(_ request: SetWorkspaceMetadataRequest) throws -> [String: JSONValue] {
        let data = try WireCoding.encodeRequest(request, id: 7)
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw DaemonError.malformedResponse("not an object")
        }
        return object
    }

    @Test func markIsSentOnlyWhenSet() throws {
        let mark = try object(SetWorkspaceMetadataRequest(workspace: .key("k1"), markedUnread: true, mutation: nil))
        #expect(mark["marked_unread"] == .bool(true))
        #expect(mark["pinned"] == nil && mark["title"] == nil)
        let clear = try object(SetWorkspaceMetadataRequest(workspace: .key("k1"), markedUnread: false, mutation: nil))
        #expect(clear["marked_unread"] == .bool(false))
        let pin = try object(SetWorkspaceMetadataRequest(workspace: .key("k1"), pinned: true, mutation: nil))
        #expect(pin["marked_unread"] == nil)
    }

    @Test func workspacesDecodeTheMarkAndOlderDaemonsAreUnmarked() throws {
        let marked = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(#"{"id":1,"key":"a","name":"a","marked_unread":true}"#.utf8))
        let older = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(#"{"id":2,"key":"b","name":"b"}"#.utf8))
        #expect(marked.markedUnread)
        #expect(!older.markedUnread)
    }

    @Test func aChangedWorkspaceUpdatesItsModel() throws {
        let store = DaemonStore()
        let tree = try Fixture.response(DaemonTree.self, "list-workspaces.json")
        store.apply(snapshot: tree)
        let generation = try #require(store.generation)
        let key: WorkspaceKey = "c7a12f08-d868-42cd-9f98-a2ca1f6d9eb1"
        #expect(store.workspace(key: key)?.markedUnread == false)
        var entity = WorkspaceSnapshot(id: 1, key: key, name: "beta")
        entity.screens = tree.workspaces[0].screens
        entity.markedUnread = true
        _ = store.apply(.workspaceChanged(WorkspaceDelta(workspace: 1, index: 0, entity: entity, workspaceRevision: 4, generation: generation)))
        #expect(store.workspace(key: key)?.markedUnread == true)
    }

    @Test func markIsAnOptionalCapability() {
        #expect(DaemonCapabilities.shared.optional.contains(DaemonCapabilities.shared.notificationMarkUnread))
        #expect(DaemonCapabilities.shared.advertised.contains("notification-mark-unread-v1"))
    }
}
