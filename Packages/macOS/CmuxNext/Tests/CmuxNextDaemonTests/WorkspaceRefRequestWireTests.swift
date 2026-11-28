import Foundation
import Testing
@testable import CmuxNextDaemon

/// The exact request lines of the requests that target a workspace by `WorkspaceRef`: a key goes out as `key`, a
/// handle as `workspace`, never both. These bytes are the contract the generated types (swift_app
/// `workspace_ref`) keep with the hand-written ones they replaced.
struct WorkspaceRefRequestWireTests {
    private static let key = WorkspaceKey(rawValue: "018f6e21-7b70-7e70-8000-0000000000c1")

    private func line(_ request: some DaemonRequest) throws -> String {
        String(decoding: try WireCoding.encodeRequest(request, id: 7), as: UTF8.self)
    }

    @Test func moveWorkspaceSendsTheRefItNames() throws {
        #expect(try line(MoveWorkspaceRequest(workspace: .handle(WorkspaceHandle(rawValue: 9)), index: 2, mutation: nil))
            == #"{"cmd":"move-workspace","id":7,"index":2,"workspace":9}"#)
        let mutation = MutationIdentity(origin: "app", mutationID: "m1")
        #expect(try line(MoveWorkspaceRequest(workspace: .key(Self.key), index: 0, mutation: mutation))
            == #"{"cmd":"move-workspace","id":7,"index":0,"key":"018f6e21-7b70-7e70-8000-0000000000c1","mutation_id":"m1","origin":"app"}"#)
    }

    @Test func setWorkspaceMetadataSendsOnlyWhatChanges() throws {
        #expect(try line(SetWorkspaceMetadataRequest(workspace: .handle(WorkspaceHandle(rawValue: 9)), mutation: nil))
            == #"{"cmd":"set-workspace-metadata","id":7,"workspace":9}"#)
        let mutation = MutationIdentity(origin: "app", mutationID: "m1")
        #expect(try line(SetWorkspaceMetadataRequest(workspace: .key(Self.key), color: .set("red"), icon: .clear,
                                                     title: .unchanged, pinned: true, markedUnread: false,
                                                     keepAwake: true, mutation: mutation))
            == #"{"cmd":"set-workspace-metadata","color":"red","icon":null,"id":7,"keep_awake":true,"key":"018f6e21-7b70-7e70-8000-0000000000c1","marked_unread":false,"mutation_id":"m1","origin":"app","pinned":true}"#)
        #expect(SetWorkspaceMetadataRequest.requiredCapability == "workspace-metadata-v1")
    }
}
