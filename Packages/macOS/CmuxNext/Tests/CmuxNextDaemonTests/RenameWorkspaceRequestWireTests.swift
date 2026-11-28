import Foundation
import Testing
@testable import CmuxNextDaemon

/// The exact request lines of rename-workspace: `expected_name_revision` goes on the wire as a decimal string
/// and `release` only when true. These bytes are the contract the generated type (swift_app `encode: decimal`)
/// keeps with the hand-written one it replaced.
struct RenameWorkspaceRequestWireTests {
    private func line(_ request: some DaemonRequest) throws -> String {
        String(decoding: try WireCoding.encodeRequest(request, id: 7), as: UTF8.self)
    }

    @Test func renameWorkspaceSendsTheRevisionAsADecimalString() throws {
        let workspace = WorkspaceRef.handle(WorkspaceHandle(rawValue: 9))
        #expect(try line(RenameWorkspaceRequest(workspace: workspace, name: "w", mutation: nil))
            == #"{"cmd":"rename-workspace","id":7,"name":"w","workspace":9}"#)
        let mutation = MutationIdentity(origin: "app", mutationID: "m1")
        #expect(try line(RenameWorkspaceRequest(workspace: workspace, name: "w", source: .user,
                                                expectedNameRevision: 18_446_744_073_709_551_615, release: true,
                                                mutation: mutation))
            == #"{"cmd":"rename-workspace","expected_name_revision":"18446744073709551615","id":7,"mutation_id":"m1","name":"w","origin":"app","release":true,"source":"user","workspace":9}"#)
    }
}
