// dot/1 relay wire protocol — Swift mirror of workers/presence/src/relayProtocol.ts.
//
// Text WebSocket messages are bounded control JSON; binary messages are data
// frames with a fixed 14-byte routing header the relay reads (and, for phone
// uploads, rewrites). Everything after the header is opaque to the relay:
// the E2E layer (DotSecureSession) owns those bytes.

public import Foundation

public enum DotWire {
    public static let protocolName = "dot/1"
    public static let dataHeaderBytes = 14
    public static let dataFrameVersion: UInt8 = 1
    public static let dataKindData: UInt8 = 1
    /// Cloudflare caps inbound WS messages at 1 MiB; stay well inside it.
    public static let maxDataFrameBytes = 1024 * 1024 - 1024
    public static let maxControlBytes = 4 * 1024

    // Application close codes (mirror relayProtocol.ts).
    public static let closeProtocolError: UInt16 = 4400
    public static let closeUnauthorized: UInt16 = 4401
    public static let closeSuperseded: UInt16 = 4409
    public static let closeCapacity: UInt16 = 4429

    public struct DataFrame: Sendable, Equatable {
        public let legID: UInt32
        public let seq: UInt64
        public let payload: Data

        public init(legID: UInt32, seq: UInt64, payload: Data) {
            self.legID = legID
            self.seq = seq
            self.payload = payload
        }
    }

    /// Encode a binary data frame: [u8 ver][u8 kind][u32be legId][u64be seq] + payload.
    public static func encodeData(_ frame: DataFrame) -> Data {
        var data = Data(capacity: dataHeaderBytes + frame.payload.count)
        data.append(dataFrameVersion)
        data.append(dataKindData)
        appendBigEndian(UInt32(frame.legID), to: &data)
        appendBigEndian(UInt64(frame.seq), to: &data)
        data.append(frame.payload)
        return data
    }

    /// Decode a binary data frame; nil when malformed or oversized.
    public static func decodeData(_ data: Data) -> DataFrame? {
        guard data.count >= dataHeaderBytes, data.count <= maxDataFrameBytes else { return nil }
        let bytes = [UInt8](data.prefix(dataHeaderBytes))
        guard bytes[0] == dataFrameVersion, bytes[1] == dataKindData else { return nil }
        let legID = bytes[2...5].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let seq = bytes[6...13].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard seq >= 1 else { return nil }
        return DataFrame(legID: legID, seq: seq, payload: data.subdata(in: dataHeaderBytes..<data.count))
    }

    private static func appendBigEndian(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    private static func appendBigEndian(_ value: UInt64, to data: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }
}

/// Control frames on the leg (text JSON). Client→relay and relay→client
/// vocabularies overlap; unknown types must be tolerated (skip, don't close),
/// so the relay can grow the protocol without breaking deployed apps.
public enum DotControlFrame: Sendable, Equatable {
    case hello(device: String, resume: String?, ack: UInt64?, acks: [UInt32: UInt64]?)
    case helloAck(legID: UInt32, resumeKey: String, epoch: String, peerOnline: Bool, replayed: Int)
    case resumeFailed(reason: String)
    case ping(ts: Double)
    case pong(ts: Double)
    case authRefresh(token: String)
    case authOK(deadline: Double)
    /// Receiver→relay: "I received download seq X" (host includes the source leg).
    case ack(seq: UInt64, leg: UInt32?)
    /// Relay→uploader: "your upload is ring-durable through seq X".
    case ackUp(seq: UInt64, leg: UInt32?)
    case peerOnline(legID: UInt32?, device: String?)
    case peerOffline(legID: UInt32?, reason: String?)
    case error(code: String, message: String)

    /// Serialize for the wire. Only frame kinds a client sends are supported.
    public func encoded() throws -> String {
        var object: [String: Any] = [:]
        switch self {
        case let .hello(device, resume, ack, acks):
            object["t"] = "hello"
            object["proto"] = DotWire.protocolName
            object["device"] = device
            if let resume { object["resume"] = resume }
            if let ack { object["ack"] = ack }
            if let acks {
                object["acks"] = Dictionary(uniqueKeysWithValues: acks.map { (String($0.key), $0.value) })
            }
        case let .ping(ts):
            object["t"] = "ping"
            object["ts"] = ts
        case let .authRefresh(token):
            object["t"] = "auth.refresh"
            object["token"] = token
        case let .ack(seq, leg):
            object["t"] = "ack"
            object["seq"] = seq
            if let leg { object["leg"] = leg }
        default:
            throw DotWireError.notAClientFrame
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else { throw DotWireError.encodingFailed }
        return text
    }

    /// Parse a relay→client control frame. Returns nil for unknown types
    /// (forward compatibility) and throws for malformed JSON.
    public static func decode(_ text: String) throws -> DotControlFrame? {
        guard text.utf8.count <= DotWire.maxControlBytes else { throw DotWireError.oversized }
        guard let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["t"] as? String
        else { throw DotWireError.malformed }
        switch type {
        case "hello.ack":
            guard let legID = uint32(object["legId"]),
                  let resumeKey = object["resumeKey"] as? String,
                  !resumeKey.isEmpty,
                  resumeKey.utf8.count <= 128,
                  let epoch = object["epoch"] as? String,
                  !epoch.isEmpty,
                  epoch.utf8.count <= 128,
                  let peerOnline = object["peerOnline"] as? Bool
            else { throw DotWireError.malformed }
            let replayed = (object["replayed"] as? NSNumber)?.intValue ?? 0
            guard replayed >= 0 else { throw DotWireError.malformed }
            return .helloAck(
                legID: legID, resumeKey: resumeKey, epoch: epoch,
                peerOnline: peerOnline, replayed: replayed
            )
        case "resume.failed":
            return .resumeFailed(reason: object["reason"] as? String ?? "unknown")
        case "pong":
            guard let ts = (object["ts"] as? NSNumber)?.doubleValue else { throw DotWireError.malformed }
            return .pong(ts: ts)
        case "ping":
            guard let ts = (object["ts"] as? NSNumber)?.doubleValue else { throw DotWireError.malformed }
            return .ping(ts: ts)
        case "auth.ok":
            guard let deadline = (object["deadline"] as? NSNumber)?.doubleValue else { throw DotWireError.malformed }
            guard deadline.isFinite else { throw DotWireError.malformed }
            return .authOK(deadline: deadline)
        case "ack":
            guard let seq = uint64(object["seq"]) else { throw DotWireError.malformed }
            return .ack(seq: seq, leg: uint32(object["leg"]))
        case "ackup":
            guard let seq = uint64(object["seq"]) else { throw DotWireError.malformed }
            return .ackUp(seq: seq, leg: uint32(object["leg"]))
        case "peer.online":
            return .peerOnline(legID: uint32(object["legId"]), device: object["device"] as? String)
        case "peer.offline":
            return .peerOffline(legID: uint32(object["legId"]), reason: object["reason"] as? String)
        case "error":
            return .error(
                code: object["code"] as? String ?? "unknown",
                message: object["message"] as? String ?? ""
            )
        default:
            return nil
        }
    }

    private static func uint32(_ value: Any?) -> UInt32? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded(.towardZero) == double else { return nil }
        let raw = number.int64Value
        guard raw >= 0, raw <= Int64(UInt32.max) else { return nil }
        return UInt32(raw)
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded(.towardZero) == double else { return nil }
        let raw = number.int64Value
        guard raw >= 0 else { return nil }
        return UInt64(raw)
    }
}

public enum DotWireError: Error, Sendable {
    case malformed
    case oversized
    case encodingFailed
    case notAClientFrame
}
