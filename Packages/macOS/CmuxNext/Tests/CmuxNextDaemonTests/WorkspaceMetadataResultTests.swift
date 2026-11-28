import Foundation
import Testing
@testable import CmuxNextDaemon

struct WorkspaceMetadataResultTests {
    private static let key = WorkspaceKey(rawValue: "018f6e21-7b70-7e70-8000-0000000000b1")

    private func decode(_ keepAwake: String?) throws -> WorkspaceMetadataResult {
        let field = keepAwake.map { ",\"keep_awake\":\($0)" } ?? ""
        let line = "{\"workspace\":7,\"key\":\"work\",\"color\":null,\"icon\":null,\"title\":null,\"pinned\":false,\"marked_unread\":false\(field),\"workspace_revision\":3,\"changed\":true,\"replayed\":false}"
        return try JSONDecoder().decode(WorkspaceMetadataResult.self, from: Data(line.utf8))
    }

    @Test func decodesKeepAwakeTrue() throws {
        #expect(try decode("true").keepAwake == true)
    }

    @Test func decodesKeepAwakeFalse() throws {
        #expect(try decode("false").keepAwake == false)
    }

    @Test func acceptsRepliesFromOlderDaemonsWithoutKeepAwake() throws {
        #expect(try decode(nil).keepAwake == nil)
    }

    @Test func encodesKeepAwakeBeforeMutation() throws {
        let request = SetWorkspaceMetadataRequest(
            workspace: .key(Self.key),
            keepAwake: true,
            mutation: MutationIdentity(origin: "cmux-next", mutationID: "metadata-order")
        )
        let value = try JSONDecoder().decode(JSONValue.self, from: WireCoding.encodeRequest(request, id: 13))
        guard case .object(let fields) = value else {
            Issue.record("request was not an object: \(value)")
            return
        }
        #expect(fields["cmd"] == .string("set-workspace-metadata"))
        #expect(fields["key"] == .string(Self.key.rawValue))
        #expect(fields["keep_awake"] == .bool(true))
        #expect(fields["origin"] == .string("cmux-next"))
        #expect(fields["mutation_id"] == .string("metadata-order"))
    }
}
