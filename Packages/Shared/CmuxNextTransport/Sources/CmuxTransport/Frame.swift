import Foundation
import CryptoKit

/// Protocol identity (decision D1). "lite" deliberately stays out of the wire
/// because real cmux adopts this package unchanged.
extension Frame {
    /// Wire protocol string, negotiated at connection open (contract 6.1).
    public static let protocolIdentifier = "cmux/peer/1"
    /// Envelope version number carried on every frame.
    public static let protocolVersion: Int64 = 1
    /// Frames larger than this are a protocol error. Bulk data is chunked by
    /// the sender, which is also what makes per-lane backpressure (5.3) real.
    public static let maxFrameLength = 8 * 1024 * 1024
}

/// One length-prefixed JSON frame (contract 6.1/6.2).
public struct Frame: Sendable, Equatable {
    /// Wire type used by ``FrameTypePolicy`` to select handling rules.
    public var type: String
    /// JSON object fields specific to this frame type.
    public var payload: [String: JSONValue]

    /// Creates an envelope value without encoding it or validating its type.
    /// - Parameters:
    ///   - type: Wire frame name.
    ///   - payload: Type-specific JSON fields; defaults to an empty object.
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
extension FrameTypePolicy {
    /// Initial control-lane identity and admission-grant exchange.
    public static let hello = "ctl.hello"
    /// Successful admission containing the host-assigned session identifier.
    public static let admit = "ctl.admit"
    /// In-session grant renewal (contract 3.6): no disconnect, no flurry.
    public static let grantUpdate = "ctl.grant-update"
    /// Acceptance or refusal of an in-session grant renewal.
    public static let grantAck = "ctl.grant-ack"
    /// Pre-expiry warning. Lives in the optional namespace on purpose: a peer
    /// that predates it ignores it instead of closing (6.3).
    public static let grantExpiring = "opt.grant-expiring"
    /// Fresh relay credential pushed host->client mid-session: the renewal
    /// shape of contract 9.7 (credentials ride the standing channel, no
    /// reconnect). Optional namespace so old peers ignore it.
    public static let relayCredential = "opt.relay-credential"
    /// Sequence-numbered, checksummed harness data.
    public static let dataChunk = "data.chunk"
    /// Committed chat message (the demo's "output burst").
    public static let chatMessage = "chat.message"
    /// LIVE draft, sent on every keystroke (the demo's "input echo").
    /// Optional namespace: an old peer misses drafts but still gets messages.
    public static let chatTyping = "opt.chat.typing"

    /// Built-in frame types understood by this protocol implementation.
    public static let allKnown: Set<String> = [
        hello, admit, grantUpdate, grantAck, grantExpiring, relayCredential,
        dataChunk, chatMessage, chatTyping,
    ]
}

/// How a decoded-but-unknown frame type must be handled (contract 6.3).
public enum FrameTypeClass: Sendable, Equatable {
    /// The receiver has a handler for this frame type.
    case known
    /// Unknown but inside the optional namespace: ignore and continue.
    case ignorableUnknown
    /// Unknown outside the optional namespace: close the connection.
    case fatalUnknown
}

/// Classifies frame names without conflating optional extensions with mandatory protocol changes.
public struct FrameTypePolicy: Sendable {
    /// Frame names this receiver explicitly understands.
    public var knownTypes: Set<String>

    /// Types in this namespace may be ignored by peers that don't know them,
    /// which is how the protocol grows without breaking old peers.
    public static let optionalPrefix = "opt."

    /// Creates a receiver policy with the supplied supported types.
    /// - Parameter knownTypes: Defaults to the protocol's built-in handlers.
    public init(knownTypes: Set<String> = FrameTypePolicy.allKnown) {
        self.knownTypes = knownTypes
    }

    /// Determines whether an unknown frame may be ignored or requires connection closure.
    /// - Parameter type: Decoded wire frame name.
    /// - Returns: Known, ignorable optional, or fatal mandatory classification.
    public func classify(_ type: String) -> FrameTypeClass {
        if knownTypes.contains(type) { return .known }
        if type.hasPrefix(Self.optionalPrefix) { return .ignorableUnknown }
        return .fatalUnknown
    }
}

/// Terminal framing or mandatory-type errors that must not be silently skipped.
public enum FrameCodecError: Error, Equatable {
    /// Encoded or advertised body length exceeded ``Frame/maxFrameLength``.
    case frameTooLarge(length: Int)
    /// A complete body could not be decoded as the JSON envelope.
    case malformedJSON
    /// Envelope version did not match ``Frame/protocolVersion``.
    case unsupportedVersion(Int64)
    /// A decoded frame used a mandatory type this peer cannot handle.
    case unknownMandatoryType(String)
}

/// Encodes one frame as a 4-byte big-endian length prefix + JSON envelope.
public struct FrameEncoder: Sendable {
    /// Creates a stateless encoder for the current protocol version.
    public init() {}

    /// Encodes one envelope and rejects bodies over the protocol size limit.
    /// - Parameter frame: Frame to transmit.
    /// - Returns: Four-byte length prefix followed by the JSON body.
    /// - Throws: A JSON encoding error or ``FrameCodecError/frameTooLarge(length:)``.
    public func encode(_ frame: Frame) throws -> Data {
        let envelope = FrameEnvelope(
            v: Frame.protocolVersion, t: frame.type, p: .object(frame.payload))
        let body = try JSONEncoder().encode(envelope)
        guard body.count <= Frame.maxFrameLength else {
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
    private let capturesEncodedFrames: Bool
    /// Encoded bytes for frames emitted by the most recent `feed` calls.
    /// Consumers that hand a stream from framed to raw mode can drain these
    /// bytes verbatim instead of re-encoding decoded JSON (which could change
    /// ordering/escaping and corrupt the legacy handoff).
    private var encodedFrames: [Data] = []

    /// Creates a decoder.
    /// - Parameter captureEncodedFrames: Retain complete wire frames for a
    ///   later framed-to-raw handoff. Keep this false for ordinary decoding so
    ///   consumed bytes are released immediately.
    public init(captureEncodedFrames: Bool = false) {
        self.capturesEncodedFrames = captureEncodedFrames
    }

    /// Graduation bridge: hands back undecoded buffered bytes when a stream
    /// switches from framed handshake to raw passthrough.
    public mutating func drainRemainder() -> Data {
        let remainder = buffer
        buffer.removeAll()
        return remainder
    }

    /// Returns encoded bytes for every frame returned by `feed` since the
    /// previous call, in the same order. The bytes are length prefix plus body.
    public mutating func drainEncodedFrames() -> [Data] {
        let frames = encodedFrames
        encodedFrames.removeAll(keepingCapacity: true)
        return frames
    }

    /// Consumes arbitrary network chunks and retains incomplete trailing frame bytes.
    ///
    /// ```swift
    /// var decoder = FrameDecoder()
    /// let frames = try decoder.feed(FrameEncoder().encode(.admit(sessionID: "session")))
    /// ```
    ///
    /// - Parameter chunk: Next bytes in stream order, possibly splitting any frame boundary.
    /// - Returns: All complete frames decoded from the accumulated input, in order.
    /// - Throws: A framing, JSON, or version error; discard this decoder after failure.
    public mutating func feed(_ chunk: Data) throws -> [Frame] {
        buffer.append(chunk)
        var frames: [Frame] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length <= Frame.maxFrameLength else {
                throw FrameCodecError.frameTooLarge(length: length)
            }
            guard buffer.count >= 4 + length else { break }
            let encoded = Data(buffer.prefix(4 + length))
            let body = Data(encoded.dropFirst(4))
            buffer.removeFirst(4 + length)
            let envelope: FrameEnvelope
            do {
                envelope = try JSONDecoder().decode(FrameEnvelope.self, from: body)
            } catch {
                throw FrameCodecError.malformedJSON
            }
            guard envelope.v == Frame.protocolVersion else {
                throw FrameCodecError.unsupportedVersion(envelope.v)
            }
            frames.append(Frame(type: envelope.t, payload: envelope.p?.objectValue ?? [:]))
            if capturesEncodedFrames {
                encodedFrames.append(encoded)
            }
        }
        return frames
    }

    /// Decodes only the first complete frame in `chunk`, leaving every byte
    /// after that frame in the decoder's remainder. This is required for a
    /// framed-to-raw handoff: one network read may coalesce the handshake
    /// frame with arbitrary application bytes that are not themselves frames.
    ///
    /// - Parameter chunk: The next arbitrary network read.
    /// - Returns: The first complete frame, or `nil` while its header/body is
    ///   still incomplete.
    /// - Throws: A framing, JSON, or version error; discard this decoder after failure.
    public mutating func feedFirst(_ chunk: Data) throws -> Frame? {
        buffer.append(chunk)
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length <= Frame.maxFrameLength else {
            throw FrameCodecError.frameTooLarge(length: length)
        }
        guard buffer.count >= 4 + length else { return nil }

        let encoded = Data(buffer.prefix(4 + length))
        let body = Data(encoded.dropFirst(4))
        buffer.removeFirst(4 + length)
        let envelope: FrameEnvelope
        do {
            envelope = try JSONDecoder().decode(FrameEnvelope.self, from: body)
        } catch {
            throw FrameCodecError.malformedJSON
        }
        guard envelope.v == Frame.protocolVersion else {
            throw FrameCodecError.unsupportedVersion(envelope.v)
        }
        if capturesEncodedFrames {
            encodedFrames.append(encoded)
        }
        return Frame(type: envelope.t, payload: envelope.p?.objectValue ?? [:])
    }
}

struct FrameEnvelope: Codable {
    var v: Int64
    var t: String
    var p: JSONValue?
}

extension Frame {
    /// Creates the initial admission envelope, binding the grant to the claimed identity.
    /// - Parameters:
    ///   - identity: Local peer identity; only its public fields enter the frame.
    ///   - grant: Host-signed admission grant for this peer.
    /// - Returns: A control hello frame; transport-key verification remains the host's job.
    public static func hello(identity: PeerIdentity, grant: PairingGrant) -> Frame {
        Frame(
            type: FrameTypePolicy.hello,
            payload: [
                "protocol": .string(Frame.protocolIdentifier),
                "app": .string(identity.appIdentity),
                "deviceId": .string(identity.deviceID),
                "key": .data(identity.publicKeyData),
                "grant": grant.payloadValue,
            ])
    }

    /// Creates a successful admission reply.
    /// - Parameter sessionID: Host-assigned identifier for the admitted session.
    /// - Returns: A control admission frame.
    public static func admit(sessionID: String) -> Frame {
        Frame(type: FrameTypePolicy.admit, payload: ["session": .string(sessionID)])
    }

    /// In-session renewal (contract 3.6): the client ships a fresh grant over
    /// the live control lane; no lane is interrupted.
    /// - Parameter grant: Fresh host-signed grant for the already-admitted peer.
    /// - Returns: A control renewal request.
    public static func grantUpdate(_ grant: PairingGrant) -> Frame {
        Frame(type: FrameTypePolicy.grantUpdate, payload: ["grant": grant.payloadValue])
    }

    /// Creates the result of an in-session grant renewal.
    /// - Parameters:
    ///   - accepted: Whether the host accepted the replacement grant.
    ///   - code: Optional stable denial reason; omitted for an ordinary success.
    /// - Returns: A control renewal acknowledgement.
    public static func grantAck(accepted: Bool, code: DenialCode? = nil) -> Frame {
        var payload: [String: JSONValue] = ["ok": .bool(accepted)]
        if let code { payload["code"] = .string(code.rawValue) }
        return Frame(type: FrameTypePolicy.grantAck, payload: payload)
    }

    /// Warns that the current admission grant will expire.
    /// - Parameter expiresAt: Grant expiry in Unix seconds.
    /// - Returns: An optional frame that older peers may ignore.
    public static func grantExpiring(expiresAt: Int64) -> Frame {
        Frame(type: FrameTypePolicy.grantExpiring, payload: ["exp": .int(expiresAt)])
    }

    /// Carries a new relay credential over the standing authenticated session.
    /// - Parameters:
    ///   - url: Relay URL to which the bearer credential is scoped.
    ///   - token: Secret relay token; do not log this frame's payload.
    /// - Returns: An optional relay-update frame.
    public static func relayCredential(url: String, token: String) -> Frame {
        Frame(
            type: FrameTypePolicy.relayCredential,
            payload: ["url": .string(url), "token": .string(token)])
    }

    /// Live keystroke echo: the FULL current draft, idempotent, so a lost or
    /// reordered frame self-heals on the next keystroke.
    /// - Parameters:
    ///   - from: Sender label used by the harness.
    ///   - text: Complete current draft, not an incremental edit.
    /// - Returns: An optional draft-update frame.
    public static func chatTyping(from: String, text: String) -> Frame {
        Frame(
            type: FrameTypePolicy.chatTyping,
            payload: ["from": .string(from), "text": .string(text)])
    }

    /// Creates one committed harness chat message.
    /// - Parameters:
    ///   - from: Sender label.
    ///   - seq: Sender's sequence number.
    ///   - text: Complete committed message.
    /// - Returns: A mandatory chat-message frame.
    public static func chatMessage(from: String, seq: Int64, text: String) -> Frame {
        Frame(
            type: FrameTypePolicy.chatMessage,
            payload: ["from": .string(from), "seq": .int(seq), "text": .string(text)])
    }

    /// Sequence-numbered, checksummed data chunk (harness spec 1.4).
    /// - Parameters:
    ///   - seq: Sequence number validated by ``TrafficValidator``.
    ///   - data: Exact payload bytes to checksum and base64-encode.
    /// - Returns: A data frame with a lowercase SHA-256 digest.
    public static func dataChunk(seq: Int64, data: Data) -> Frame {
        let digest = HexEncoding().lowercase(SHA256.hash(data: data))
        return Frame(
            type: FrameTypePolicy.dataChunk,
            payload: [
                "seq": .int(seq),
                "data": .data(data),
                "sha256": .string(digest),
            ])
    }

}
