@testable import CmuxAcpmux
import Foundation
import Testing

@Suite struct AcpmuxWebBridgeProtocolTests {
    @Test func rowEncodingKeepsStableIdentityAndContentVersion() throws {
        let row = TranscriptRow(
            id: "assistant-1",
            version: 7,
            at: 123,
            content: .assistant(text: "stream", isStreaming: true)
        )
        let encoded = try JSONEncoder().encode(AcpmuxWebRow(row: row))
        let decoded = try JSONDecoder().decode(AcpmuxWebRow.self, from: encoded)
        #expect(decoded.id == "assistant-1")
        #expect(decoded.version == 7)
        #expect(decoded.kind == "assistant")
        #expect(decoded.text == "stream")
        #expect(decoded.streaming == true)
    }

    @Test func activityRowsEncodeToolsAndThoughts() throws {
        let row = TranscriptRow(
            id: "activity-1",
            at: 123,
            content: .activity(TranscriptActivityGroup(items: [
                .thought("thinking"),
                .tool(TranscriptToolCall(id: "tool-1", title: "Read", kind: "read", status: "completed", inputSummary: "file.swift", output: nil)),
            ], isLive: false))
        )
        let decoded = try JSONDecoder().decode(AcpmuxWebRow.self, from: JSONEncoder().encode(AcpmuxWebRow(row: row)))
        #expect(decoded.items?.count == 2)
        #expect(decoded.items?.last?.tool?.id == "tool-1")
        #expect(decoded.toolCount == 1)
    }
}
