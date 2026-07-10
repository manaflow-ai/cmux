import Foundation
import Testing
@testable import CmuxSimulator

@Suite("Web Inspector host-worker streaming")
struct SimulatorWebInspectorChunkTests {
    @Test("Large raw messages split into ordered bounded chunks")
    func chunksRemainUnderFrameBudget() throws {
        let payload = Data(repeating: 0x61, count: 700_000)
        let sessionID = UUID()
        let messageID = UUID()

        let chunker = SimulatorWebInspectorMessageChunker()
        let chunks = chunker.chunks(
            sessionID: sessionID,
            messageID: messageID,
            payload: payload
        )

        #expect(chunks.count == 4)
        #expect(chunks.map(\.sequence) == [0, 1, 2, 3])
        #expect(chunks.dropLast().allSatisfy { !$0.isFinal })
        #expect(chunks.last?.isFinal == true)
        #expect(chunks.allSatisfy {
            $0.payload.count <= chunker.maximumPayloadLength
        })
        #expect(chunks.reduce(into: Data()) { $0.append($1.payload) } == payload)
        for chunk in chunks {
            let encoded = try JSONEncoder().encode(SimulatorWorkerOutbound.webInspectorMessage(chunk))
            #expect(encoded.count < SimulatorLengthPrefixedMessageChannel.maximumFrameLength)
        }
    }

    @Test("An empty raw message still produces one terminal chunk")
    func emptyMessage() {
        let chunks = SimulatorWebInspectorMessageChunker().chunks(
            sessionID: UUID(),
            payload: Data()
        )
        #expect(chunks.count == 1)
        #expect(chunks[0].sequence == 0)
        #expect(chunks[0].isFinal)
        #expect(chunks[0].payload.isEmpty)
    }
}
