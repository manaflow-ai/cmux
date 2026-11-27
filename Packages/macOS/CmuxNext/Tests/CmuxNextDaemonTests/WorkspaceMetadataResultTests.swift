import Foundation
import Testing
@testable import CmuxNextDaemon

struct WorkspaceMetadataResultTests {
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
}
