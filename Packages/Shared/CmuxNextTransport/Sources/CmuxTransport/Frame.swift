import Foundation
import CryptoKit

/// Protocol identity (decision D1). "lite" deliberately stays out of the wire
/// because real cmux adopts this package unchanged.
public enum CmuxPeerProtocol {
    /// Wire protocol string, negotiated at connection open (contract 6.1).
    public static let identifier = "cmux/peer/1"
    /// Envelope version number carried on every frame.
    public static let version: Int64 = 1
    /// Frames larger than this are a protocol error. Bulk data is chunked by
    /// the sender, which is also what makes per-lane backpressure (5.3) real.
    public static let maxFrameLength = 8 * 1024 * 1024
}

/// One length-prefixed JSON frame (contract 6.1/6.2).
public struct Frame: Sendable, Equatable {
    public var type: String
    public var payload: [String: JSONValue]

    public init(type: String, payload: [String: JSONValue] = [:]) {
        self.type = type
        self.payload = payload
    }
}

/// Frame type names for `cmux/peer/1`.
///
/// There is deliberately NO deny or close frame: denial and attributed-close
/// reasons travel in the connection termination itself (contract 3.3 v7), the
/// substrate's own close mechanism, as the single source of truth. Richer
/// denial detail, if ever needed, rides an additive `opt.*` frame.
public enum FrameTypes {
    public static let hello = "ctl.hello"
    public static let admit = "ctl.admit"
    /// In-session grant renewal (contract 3.6): no disconnect, no flurry.
    public static let grantUpdate = "ctl.grant-update"
    public static let grantAck = "ctl.grant-ack"
    /// Pre-expiry warning. Lives in the optional namespace on purpose: a peer
    /// that predates it ignores it instead of closing (6.3).
    public static let grantExpiring = "opt.grant-expiring"
    /// Fresh relay credential pushed host->client mid-session: the renewal
    /// shape of contract 9.7 (credentials ride the standing channel, no
    /// reconnect). Optional namespace so old peers ignore it.
    public static let relayCredential = "opt.relay-credential"
    public static let dataChunk = "data.chunk"
    /// Committed chat message (the demo's "output burst").
    public static let chatMessage = "chat.message"
    /// LIVE draft, sent on every keystroke (the demo's "input echo").
    /// Optional namespace: an old peer misses drafts but still gets messages.
    public static let chatTyping = "opt.chat.typing"

    public static let allKnown: Set<String> = [
        hello, admit, grantUpdate, grantAck, dataChunk, chatMessage,
    ]
}

/// How a decoded-but-unknown frame type must be handled (contract 6.3).
public enum FrameTypeClass: Sendable, Equatable {
    case known
    /// Unknown but inside the optional namespace: ignore and continue.
    case ignorableUnknown
    /// Unknown outside the optional namespace: close the connection.
    case fatalUnknown
}

public struct FrameTypePolicy: Sendable {
    public var knownTypes: Set<String>

    /// Types in this namespace may be ignored by peers that don't know them,
    /// which is how the protocol grows without breaking old peers.
    public static let optionalPrefix = "opt."

    public init(knownTypes: Set<String> = FrameTypes.allKnown) {
        self.knownTypes = knownTypes
    }

    public func classify(_ type: String) -> FrameTypeClass {
        if knownTypes.contains(type) { return .known }
        if type.hasPrefix(Self.optionalPrefix) { return .ignorableUnknown }
        return .fatalUnknown
    }
}

public enum FrameCodecError: Error, Equatable {
    case frameTooLarge(length: Int)
    case malformedJSON
    case unsupportedVersion(Int64)
}

/// Encodes one frame as a 4-byte big-endian length prefix + JSON envelope.
public struct FrameEncoder: Sendable {
    public init() {}

    public func encode(_ frame: Frame) throws -> Data {
        let envelope = FrameEnvelope(
            v: CmuxPeerProtocol.version, t: frame.type, p: .object(frame.payload))
        let body = try JSONEncoder().encode(envelope)
        guard body.count <= CmuxPeerProtocol.maxFrameLength else {
            throw FrameCodecError.frameTooLarge(length: body.count)
        }
        var data = Data(capacity: 4 + body.count)
        let length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: length) { data.append(contentsOf: $0) }
        data.append(body)
        return data
    }
}

/// Incremental decoder: feed arbitrary chunks (network reads split anywhere),
/// get back every complete frame.
public struct FrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    /// Graduation bridge: hands back undecoded buffered bytes when a stream
    /// switches from framed handshake to raw passthrough.
    public mutating func drainRemainder() -> Data {
        let remainder = buffer
        buffer.removeAll()
        return remainder
    }

    public mutating func feed(_ chunk: Data) throws -> [Frame] {
        buffer.append(chunk)
        var frames: [Frame] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length <= CmuxPeerProtocol.maxFrameLength else {
                throw FrameCodecError.frameTooLarge(length: length)
            }
            guard buffer.count >= 4 + length else { break }
            let body = Data(buffer.dropFirst(4).prefix(length))
            buffer.removeFirst(4 + length)
            let envelope: FrameEnvelope
            do {
                envelope = try JSONDecoder().decode(FrameEnvelope.self, from: body)
            } catch {
                throw FrameCodecError.malformedJSON
            }
            guard envelope.v == CmuxPeerProtocol.version else {
                throw FrameCodecError.unsupportedVersion(envelope.v)
            }
            frames.append(Frame(type: envelope.t, payload: envelope.p?.objectValue ?? [:]))
        }
        return frames
    }
}

struct FrameEnvelope: Codable {
    var v: Int64
    var t: String
    var p: JSONValue?
}

/// Fast lowercase hex for the data-chunk digest, which runs per frame on BOTH
/// hot paths (send-side mint in `Frame.dataChunk`, receive-side re-hash in
/// `TrafficValidator.ingest`). A per-byte `String(format:)` trip through
/// Foundation's formatter dominated those paths.
enum HexEncoding {
    private static let digits = Array("0123456789abcdef".utf8)

    static func lowercase<Bytes: Sequence>(_ bytes: Bytes) -> String
    where Bytes.Element == UInt8 {
        var utf8 = [UInt8]()
        utf8.reserveCapacity(bytes.underestimatedCount * 2)
        for byte in bytes {
            utf8.append(digits[Int(byte >> 4)])
            utf8.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: utf8, as: UTF8.self)
    }
}

extension Frame {
    public static func hello(identity: PeerIdentity, grant: PairingGrant) -> Frame {
        Frame(
            type: FrameTypes.hello,
            payload: [
                "protocol": .string(CmuxPeerProtocol.identifier),
                "app": .string(identity.appIdentity),
                "deviceId": .string(identity.deviceID),
                "key": .data(identity.publicKeyData),
                "grant": grant.payloadValue,
            ])
    }

    public static func admit(sessionID: String) -> Frame {
        Frame(type: FrameTypes.admit, payload: ["session": .string(sessionID)])
    }

    /// In-session renewal (contract 3.6): the client ships a fresh grant over
    /// the live control lane; no lane is interrupted.
    public static func grantUpdate(_ grant: PairingGrant) -> Frame {
        Frame(type: FrameTypes.grantUpdate, payload: ["grant": grant.payloadValue])
    }

    public static func grantAck(accepted: Bool, code: DenialCode? = nil) -> Frame {
        var payload: [String: JSONValue] = ["ok": .bool(accepted)]
        if let code { payload["code"] = .string(code.rawValue) }
        return Frame(type: FrameTypes.grantAck, payload: payload)
    }

    public static func grantExpiring(expiresAt: Int64) -> Frame {
        Frame(type: FrameTypes.grantExpiring, payload: ["exp": .int(expiresAt)])
    }

    public static func relayCredential(url: String, token: String) -> Frame {
        Frame(
            type: FrameTypes.relayCredential,
            payload: ["url": .string(url), "token": .string(token)])
    }

    /// Live keystroke echo: the FULL current draft, idempotent, so a lost or
    /// reordered frame self-heals on the next keystroke.
    public static func chatTyping(from: String, text: String) -> Frame {
        Frame(
            type: FrameTypes.chatTyping,
            payload: ["from": .string(from), "text": .string(text)])
    }

    public static func chatMessage(from: String, seq: Int64, text: String) -> Frame {
        Frame(
            type: FrameTypes.chatMessage,
            payload: ["from": .string(from), "seq": .int(seq), "text": .string(text)])
    }

    /// Sequence-numbered, checksummed data chunk (harness spec 1.4).
    public static func dataChunk(seq: Int64, data: Data) -> Frame {
        let digest = HexEncoding.lowercase(SHA256.hash(data: data))
        return Frame(
            type: FrameTypes.dataChunk,
            payload: [
                "seq": .int(seq),
                "data": .data(data),
                "sha256": .string(digest),
            ])
    }

}
