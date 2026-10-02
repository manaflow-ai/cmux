import Foundation
import Testing
@testable import CmuxNextDaemon

/// The sidebar workspace pin (`workspace-pin-v1`): `pinned` on
/// `set-workspace-metadata` and on every workspace entity.
@MainActor struct WorkspacePinTests {
    private func object(_ request: SetWorkspaceMetadataRequest) throws -> [String: JSONValue] {
        let data = try WireCoding.encodeRequest(request, id: 7)
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw DaemonError.malformedResponse("not an object")
        }
        return object
    }

    @Test func pinIsSentOnlyWhenSet() throws {
        let pin = try object(SetWorkspaceMetadataRequest(workspace: .key("k1"), pinned: true, mutation: nil))
        #expect(pin["pinned"] == .bool(true))
        #expect(pin["color"] == nil && pin["title"] == nil)
        let color = try object(SetWorkspaceMetadataRequest(workspace: .key("k1"), color: .set("red"), mutation: nil))
        // An absent pin leaves it as it is.
        #expect(color["pinned"] == nil)
    }

    @Test func workspacesDecodeTheirPinAndOlderDaemonsAreUnpinned() throws {
        let pinned = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(#"{"id":1,"key":"a","name":"a","pinned":true}"#.utf8))
        let older = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(#"{"id":2,"key":"b","name":"b"}"#.utf8))
        #expect(pinned.pinned)
        #expect(!older.pinned)
    }

    @Test func aChangedWorkspaceUpdatesItsModel() throws {
        let store = DaemonStore()
        let tree = try Fixture.response(DaemonTree.self, "list-workspaces.json")
        store.apply(snapshot: tree)
        let generation = try #require(store.generation)
        let key: WorkspaceKey = "c7a12f08-d868-42cd-9f98-a2ca1f6d9eb1"
        #expect(store.workspace(key: key)?.pinned == false)
        var entity = WorkspaceSnapshot(id: 1, key: key, name: "beta")
        entity.screens = tree.workspaces[0].screens
        entity.pinned = true
        _ = store.apply(.workspaceChanged(WorkspaceDelta(workspace: 1, index: 0, entity: entity, workspaceRevision: 4, generation: generation)))
        #expect(store.workspace(key: key)?.pinned == true)
    }

    @Test func pinIsServedByThePinnedDaemon() {
        #expect(!DaemonCapabilities.shared.awaitingPin.contains(DaemonCapabilities.shared.workspacePin))
        #expect(DaemonCapabilities.shared.optional.contains(DaemonCapabilities.shared.workspacePin))
        #expect(DaemonCapabilities.shared.advertised.contains("workspace-pin-v1"))
    }
}
