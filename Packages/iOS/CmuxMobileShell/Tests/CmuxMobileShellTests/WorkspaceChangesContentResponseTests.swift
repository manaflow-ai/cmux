import CmuxAgentChat
import Foundation
import Testing

@testable import CmuxMobileShell

@Suite struct WorkspaceChangesContentResponseTests {
    @Test func decodesFlatArtifactStatWithFingerprint() throws {
        let data = Data("""
        {
          "exists": true,
          "is_directory": false,
          "size": 42,
          "modified_at": 100,
          "kind": "text",
          "mime_type": "text/plain",
          "content_fingerprint": "stat:42:100:2:300:200"
        }
        """.utf8)

        let response = try ChatWireCoding().decode(
            WorkspaceChangesContentResponse<ChatArtifactStat>.self,
            from: data
        )

        #expect(response.value.size == 42)
        #expect(response.contentFingerprint == "stat:42:100:2:300:200")
    }

    @Test func decodesLegacyArtifactChunkWithoutFingerprint() throws {
        let data = Data("""
        {
          "data_b64": "YWJj",
          "offset": 0,
          "total_size": 3,
          "eof": true
        }
        """.utf8)

        let response = try ChatWireCoding().decode(
            WorkspaceChangesContentResponse<ChatArtifactChunk>.self,
            from: data
        )

        #expect(response.value.data == Data("abc".utf8))
        #expect(response.contentFingerprint == nil)
    }
}
