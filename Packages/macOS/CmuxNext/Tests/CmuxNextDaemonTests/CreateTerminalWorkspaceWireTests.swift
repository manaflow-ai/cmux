import Foundation
import Testing
@testable import CmuxNextDaemon

/// A new terminal workspace is one daemon request (`create-terminal-workspace-v1`): the first terminal's
/// `create-terminal` asks for its workspace too. It was two requests (`create-workspace`, `create-terminal`) with an
/// empty workspace between them.
struct CreateTerminalWorkspaceWireTests {
    private static let key = WorkspaceKey(rawValue: "018f6e21-7b70-7e70-8000-0000000000c1")

    private static func fields(_ request: CreateTerminalRequest) throws -> [String: JSONValue] {
        guard case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: WireCoding.encodeRequest(request, id: 7)) else { return [:] }
        return fields
    }

    private static func first(in key: WorkspaceKey, keyed: Bool = true) -> CreateTerminalRequest {
        CreateTerminalRequest(workspace: .key(key), cwd: "/tmp", terminalID: keyed ? TerminalID.generate() : nil,
                              mutation: keyed ? MutationIdentity(origin: "cmux-next", mutationID: "first-terminal") : nil)
    }

    @Test func theFirstTerminalAsksForItsWorkspace() throws {
        let request = NewTerminalWorkspace(key: Self.key, name: "shell").applied(to: Self.first(in: Self.key))
        let fields = try Self.fields(request)
        #expect(fields["cmd"] == .string("create-terminal"))
        #expect(fields["key"] == .string(Self.key.rawValue))
        #expect(fields["create_workspace"] == .bool(true))
        #expect(fields["workspace_name"] == .string("shell"))
        #expect(fields["cwd"] == .string("/tmp"), "the program fields stay top-level fields of create-terminal")
    }

    /// A terminal of another workspace, or one the daemon cannot replay (no terminal id or mutation), stays plain.
    @Test func anotherTerminalStaysPlain() throws {
        let new = NewTerminalWorkspace(key: Self.key, name: "shell")
        let other = WorkspaceKey(rawValue: "018f6e21-7b70-7e70-8000-0000000000c9")
        #expect(try Self.fields(new.applied(to: Self.first(in: other)))["create_workspace"] == nil)
        #expect(try Self.fields(new.applied(to: Self.first(in: Self.key, keyed: false)))["create_workspace"] == nil)
        #expect(try Self.fields(Self.first(in: Self.key))["create_workspace"] == nil, "a plain request has no such field")
    }
}
