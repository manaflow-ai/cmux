import CmuxAgentReplica
import Foundation
import Testing

@Suite struct DemoFixtureDecodingTests {
    /// The bundled demo transcript must decode with the CURRENT replay
    /// encoding; a hand-edited or stale fixture silently breaks the demo
    /// screen's playback, which is this program's UI evidence surface.
    @Test func bundledDemoTranscriptDecodesWithoutSkippedLines() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CmuxAgentGUIUI/Resources/demo-transcript.jsonl")
        let data = try Data(contentsOf: fixtureURL)
        let log = ReplicaReplayLog.decodeJSONL(data)
        #expect(log.records.count >= 10)
        #expect(log.skippedLineCount == 0)
    }
}
