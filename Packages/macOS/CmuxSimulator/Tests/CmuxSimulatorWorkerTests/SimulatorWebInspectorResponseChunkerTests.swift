import CmuxSimulator
import Foundation
import Testing
@testable import CmuxSimulatorWorker

@Suite("Web Inspector worker response chunking")
struct SimulatorWebInspectorResponseChunkerTests {
    @Test("Oversized responses cross the worker boundary once as a bounded truncated stream")
    func oversizedResponseIsBounded() throws {
        let sessionID = UUID()
        let messageID = UUID()
        let payload = Data((
            "{\"result\":\""
                + String(
                    repeating: "x",
                    count: SimulatorWebInspectorMessageChunk.maximumRetainedResponseBytes * 2
                )
                + "\",\"id\":42}"
        ).utf8)

        let chunks = SimulatorWebInspectorResponseChunker().chunks(
            payload: payload,
            sessionID: sessionID,
            messageID: messageID
        )

        #expect(chunks.count == 1)
        #expect(chunks.reduce(0) { $0 + $1.payload.count }
            == SimulatorWebInspectorMessageChunk.maximumRetainedResponseBytes)
        let final = try #require(chunks.last)
        #expect(final.isFinal)
        #expect(final.isTruncated)
        #expect(final.requestIDToken == Data("42".utf8))
    }
}
