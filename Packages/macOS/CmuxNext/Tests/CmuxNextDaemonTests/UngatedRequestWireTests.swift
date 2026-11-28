import Foundation
import Testing
@testable import CmuxNextDaemon

/// The exact request line of `create-workspace`, which the schema gates on `workspace-registry-v1` and the app
/// sends without asking (`requiredCapability` nil): these bytes, and the ungated send, are the contract the
/// generated type (swift_app request `ungated`) keeps with the hand-written one it replaced.
struct UngatedRequestWireTests {
    private func line(_ request: some DaemonRequest) throws -> String {
        String(decoding: try WireCoding.encodeRequest(request, id: 7), as: UTF8.self)
    }

    private static let key = WorkspaceKey(rawValue: "018f6e21-7b70-7e70-8000-0000000000b1")

    @Test func aCreateSendsItsNameKeySourceAndMutation() throws {
        let request = CreateWorkspaceRequest(name: "w", key: Self.key, nameSource: .user,
                                             mutation: MutationIdentity(origin: "app", mutationID: "m1"))
        #expect(try line(request)
            == #"{"cmd":"create-workspace","id":7,"key":"018f6e21-7b70-7e70-8000-0000000000b1","mutation_id":"m1","name":"w","name_source":"user","origin":"app"}"#)
    }

    @Test func aBareCreateSendsItsCommandAlone() throws {
        #expect(try line(CreateWorkspaceRequest(mutation: nil)) == #"{"cmd":"create-workspace","id":7}"#)
    }

    @Test func aCreateGoesToADaemonThatDoesNotAdvertiseTheRegistry() throws {
        #expect(CreateWorkspaceRequest.requiredCapability == nil)
        try CreateWorkspaceRequest.requireServed(by: nil)
    }
}
