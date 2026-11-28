import Foundation
import Testing
@testable import CmuxNextDaemon

struct CloseWorkspaceRequestWireTests {
    private static let key = WorkspaceKey(rawValue: "018f6e21-7b70-7e70-8000-0000000000d1")

    private func fields(_ request: CloseWorkspaceRequest) throws -> [String: JSONValue] {
        let value = try JSONDecoder().decode(JSONValue.self, from: WireCoding.encodeRequest(request, id: 11))
        guard case .object(let fields) = value else {
            Issue.record("not an object: \(value)")
            return [:]
        }
        return fields
    }

    @Test func reasonIsOmittedWhenTerminalsAreKept() throws {
        let sent = try fields(CloseWorkspaceRequest(workspace: .key(Self.key), reason: .sessionEnd, mutation: nil))
        #expect(sent["end_terminals"] == nil)
        #expect(sent["reason"] == nil)
    }

    @Test func reasonIsSentWithEndTerminals() throws {
        let sent = try fields(CloseWorkspaceRequest(workspace: .key(Self.key), endTerminals: true, reason: .sessionEnd, mutation: nil))
        #expect(sent["end_terminals"] == .bool(true))
        #expect(sent["reason"] == .string("session_end"))
    }
}
