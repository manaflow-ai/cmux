import Foundation

/// Splits raw inspector output into process-safe protocol messages.
public struct SimulatorWebInspectorMessageChunker: Sendable {
    /// Payload size chosen to stay far below the four MiB outer JSON frame
    /// after `Data` is Base64 encoded by `JSONEncoder`.
    public let maximumPayloadLength: Int

    /// Creates a chunker with a bounded payload size.
    /// - Parameter maximumPayloadLength: Maximum raw bytes carried by one chunk.
    public init(maximumPayloadLength: Int = 192 * 1024) {
        self.maximumPayloadLength = maximumPayloadLength
    }

    /// Produces at least one ordered chunk for a raw inspector message.
    public func chunks(
        sessionID: UUID,
        messageID: UUID = UUID(),
        payload: Data
    ) -> [SimulatorWebInspectorMessageChunk] {
        guard maximumPayloadLength > 0 else { return [] }
        if payload.isEmpty {
            return [SimulatorWebInspectorMessageChunk(
                sessionID: sessionID,
                messageID: messageID,
                sequence: 0,
                isFinal: true,
                payload: Data()
            )]
        }

        var result: [SimulatorWebInspectorMessageChunk] = []
        result.reserveCapacity((payload.count + maximumPayloadLength - 1) / maximumPayloadLength)
        var offset = 0
        var sequence = 0
        while offset < payload.count {
            let end = min(offset + maximumPayloadLength, payload.count)
            result.append(SimulatorWebInspectorMessageChunk(
                sessionID: sessionID,
                messageID: messageID,
                sequence: sequence,
                isFinal: end == payload.count,
                payload: payload.subdata(in: offset..<end)
            ))
            offset = end
            sequence += 1
        }
        return result
    }
}
