import Foundation

/// Splits raw inspector output into process-safe protocol messages.
public enum SimulatorWebInspectorMessageChunker {
    /// Payload size chosen to stay far below the four MiB outer JSON frame
    /// after `Data` is Base64 encoded by `JSONEncoder`.
    public static let defaultMaximumPayloadLength = 192 * 1024

    /// Produces at least one ordered chunk for a raw inspector message.
    public static func chunks(
        sessionID: UUID,
        messageID: UUID = UUID(),
        payload: Data,
        maximumPayloadLength: Int = defaultMaximumPayloadLength
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
