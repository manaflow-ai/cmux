import CmuxSimulator
import Foundation

struct SimulatorWebInspectorResponseChunker {
    private let chunker = SimulatorWebInspectorMessageChunker()

    func chunks(
        payload: Data,
        sessionID: UUID,
        messageID: UUID = UUID()
    ) -> [SimulatorWebInspectorMessageChunk] {
        var extractor = SimulatorWebInspectorRequestIDTokenExtractor()
        extractor.ingest(payload)
        let retainedCount = min(
            payload.count,
            SimulatorWebInspectorMessageChunk.maximumRetainedResponseBytes
        )
        let retained = payload.prefix(retainedCount)
        let isTruncated = retainedCount < payload.count
        if retained.isEmpty {
            return [SimulatorWebInspectorMessageChunk(
                sessionID: sessionID,
                messageID: messageID,
                sequence: 0,
                isFinal: true,
                payload: Data(),
                isTruncated: isTruncated,
                requestIDToken: extractor.requestIDToken
            )]
        }
        let maximum = chunker.maximumPayloadLength
        var result: [SimulatorWebInspectorMessageChunk] = []
        var offset = 0
        var sequence = 0
        while offset < retainedCount {
            let end = min(offset + maximum, retainedCount)
            let isFinal = end == retainedCount
            result.append(SimulatorWebInspectorMessageChunk(
                sessionID: sessionID,
                messageID: messageID,
                sequence: sequence,
                isFinal: isFinal,
                payload: payload.subdata(in: offset..<end),
                isTruncated: isFinal && isTruncated,
                requestIDToken: isFinal ? extractor.requestIDToken : nil
            ))
            offset = end
            sequence += 1
        }
        return result
    }
}
