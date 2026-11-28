import Foundation
import Testing
@testable import CmuxNextDaemon

/// The exact request lines of close-workspace, whose `reason` goes on the wire only with `end_terminals`. These bytes are the contract the generated types (swift_app
/// `with`) keep with the hand-written ones they replaced.
struct SentWithRequestWireTests {
    private static let key = WorkspaceKey(rawValue: "018f6e21-7b70-7e70-8000-0000000000c1")

    private func line(_ request: some DaemonRequest) throws -> String {
        String(decoding: try WireCoding.encodeRequest(request, id: 7), as: UTF8.self)
    }

    @Test func closeWorkspaceSendsReasonOnlyWithEndTerminals() throws {
        let workspace = WorkspaceRef.handle(WorkspaceHandle(rawValue: 9))
        #expect(try line(CloseWorkspaceRequest(workspace: workspace, mutation: nil))
            == #"{"cmd":"close-workspace","id":7,"workspace":9}"#)
        #expect(try line(CloseWorkspaceRequest(workspace: workspace, reason: .sessionEnd, mutation: nil))
            == #"{"cmd":"close-workspace","id":7,"workspace":9}"#)
        let mutation = MutationIdentity(origin: "app", mutationID: "m1")
        #expect(try line(CloseWorkspaceRequest(workspace: .key(Self.key), endTerminals: true, reason: .sessionEnd,
                                               ifEmpty: true, mutation: mutation))
            == #"{"cmd":"close-workspace","end_terminals":true,"id":7,"if_empty":true,"key":"018f6e21-7b70-7e70-8000-0000000000c1","mutation_id":"m1","origin":"app","reason":"session_end"}"#)
    }
}
