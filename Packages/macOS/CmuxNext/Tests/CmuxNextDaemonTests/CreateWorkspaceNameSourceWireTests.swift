import Foundation
import Testing
@testable import CmuxNextDaemon

/// #56422: the app's `create-workspace` for `agents chat new --name` says the name is the caller's
/// (`name_source: "user"`), so the daemon pins it and the chat's auto title never replaces it in the
/// sidebar. A starting name (Cmd-N's `workspace-N`, a moved tab's name) sends no source.
struct CreateWorkspaceNameSourceWireTests {
    private static let key = WorkspaceKey(rawValue: "018f6e21-7b70-7e70-8000-0000000000c1")

    private func fields(_ request: CreateWorkspaceRequest) throws -> [String: JSONValue] {
        let value = try JSONDecoder().decode(JSONValue.self, from: WireCoding.encodeRequest(request, id: 3))
        guard case .object(let fields) = value else { Issue.record("not an object: \(value)"); return [:] }
        return fields
    }

    @Test func anExplicitNameIsSentAsTheCallers() throws {
        let sent = try fields(CreateWorkspaceRequest(name: "56151: Plan bar icon alignment", key: Self.key, nameSource: .user, mutation: nil))
        #expect(sent["name"] == .string("56151: Plan bar icon alignment"))
        #expect(sent["name_source"] == .string("user"))
    }

    @Test func aStartingNameSendsNoSource() throws {
        #expect(try fields(CreateWorkspaceRequest(name: "workspace-4", key: Self.key, mutation: nil))["name_source"] == nil)
        // No name, nothing to pin.
        #expect(try fields(CreateWorkspaceRequest(name: nil, key: Self.key, nameSource: .user, mutation: nil))["name_source"] == nil)
    }
}
