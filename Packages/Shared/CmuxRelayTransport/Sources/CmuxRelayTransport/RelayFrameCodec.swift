// Binary data-frame codec for the mobile relay. Mirrors the TypeScript
// contract in workers/mobile-relay/src/protocol.ts exactly:
// `[u8 type][u32 BE sessionId][payload]`, where by endpoint convention the
// first payload byte is a channel tag (RelayProtocol.channel*). The relay
// only reads the 5-byte header; channels are interpreted here on the
// endpoints.

import Foundation

public struct RelayDataFrame: Equatable, Sendable {
    public let sessionID: UInt32
    /// Raw payload including the leading channel byte.
    public let payload: Data

    public init(sessionID: UInt32, payload: Data) {
        self.sessionID = sessionID
        self.payload = payload
    }
}

public enum RelayFrameCodec {
    public static func encodeDataFrame(sessionID: UInt32, payload: Data) -> Data {
        var frame = Data(capacity: RelayProtocol.dataHeaderBytes + payload.count)
        frame.append(RelayProtocol.dataFrameType)
        withUnsafeBytes(of: sessionID.bigEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    /// Returns nil for anything that is not a well-formed, size-bounded data
    /// frame. Callers treat nil as a protocol violation.
    public static func decodeDataFrame(_ data: Data) -> RelayDataFrame? {
        guard data.count >= RelayProtocol.dataHeaderBytes else { return nil }
        guard data.count <= RelayProtocol.dataHeaderBytes + RelayProtocol.maxDataPayloadBytes else {
            return nil
        }
        // Data slices keep their parent's indices; normalize before indexing.
        let bytes = [UInt8](data.prefix(RelayProtocol.dataHeaderBytes))
        guard bytes[0] == RelayProtocol.dataFrameType else { return nil }
        let sessionID = UInt32(bytes[1]) << 24 | UInt32(bytes[2]) << 16
            | UInt32(bytes[3]) << 8 | UInt32(bytes[4])
        return RelayDataFrame(
            sessionID: sessionID,
            payload: data.subdata(in: (data.startIndex + RelayProtocol.dataHeaderBytes)..<data.endIndex)
        )
    }

    /// Prefixes application bytes with their channel tag.
    public static func channelPayload(channel: UInt8, data: Data) -> Data {
        var payload = Data(capacity: 1 + data.count)
        payload.append(channel)
        payload.append(data)
        return payload
    }

    /// Splits a payload into its channel tag and application bytes.
    public static func splitChannel(_ payload: Data) -> (channel: UInt8, data: Data)? {
        guard let first = payload.first else { return nil }
        return (first, payload.subdata(in: (payload.startIndex + 1)..<payload.endIndex))
    }
}
