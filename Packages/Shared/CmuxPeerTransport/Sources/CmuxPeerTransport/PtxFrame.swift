import Foundation

/// Wire protocol identity for the v2 peer transport. Distinct from the legacy
/// transport's `cmux/mobile/1` so both hosts listen concurrently in one app.
public enum PtxProtocol {
    /// Doubles as the QUIC ALPN and the value of the hello `protocol` field.
    public static let identifier = "cmux/ptx/1"
    public static let version: Int64 = 1
    /// Frames above this are a protocol error; bulk data rides raw streams.
    public static let maxFrameLength = 8 * 1024 * 1024
}

/// One length-prefixed JSON control frame.
public struct PtxFrame: Sendable, Equatable {
    public var type: String
    public var payload: [String: PtxJSON]

    public init(type: String, payload: [String: PtxJSON] = [:]) {
        self.type = type
        self.payload = payload
    }
}

public enum PtxFrameType {
    /// Dialer's first frame on the control stream.
    public static let hello = "ctl.hello"
    /// Host's admission response. Denials never get a frame: the reason rides
    /// the QUIC close itself, the one channel that survives shutdown.
    public static let admit = "ctl.admit"
    /// Liveness probe, either direction; receiver echoes `ctl.pong`.
    public static let ping = "ctl.ping"
    public static let pong = "ctl.pong"
    /// Fresh relay credential pushed host→client mid-session. Optional
    /// namespace: a peer that predates it ignores it instead of closing.
    public static let relayCredential = "opt.relay-credential"

    public static let allKnown: Set<String> = [hello, admit, ping, pong]

    /// Unknown types inside `opt.` are ignored (additive evolution); unknown
    /// types outside it are a protocol violation.
    public static let optionalPrefix = "opt."
}

public enum PtxFrameError: Error, Equatable {
    case frameTooLarge(Int)
    case malformedJSON
    case unsupportedVersion(Int64)
}

private struct PtxFrameEnvelope: Codable {
    var v: Int64
    var t: String
    var p: PtxJSON?
}

public struct PtxFrameEncoder: Sendable {
    public init() {}

    public func encode(_ frame: PtxFrame) throws -> Data {
        let envelope = PtxFrameEnvelope(
            v: PtxProtocol.version, t: frame.type, p: .object(frame.payload))
        let body = try JSONEncoder().encode(envelope)
        guard body.count <= PtxProtocol.maxFrameLength else {
            throw PtxFrameError.frameTooLarge(body.count)
        }
        var data = Data(capacity: 4 + body.count)
        let length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: length) { data.append(contentsOf: $0) }
        data.append(body)
        return data
    }
}

/// Incremental decoder. Deliberately LAZY: `feed` only buffers, and `next`
/// parses exactly one frame from the head. On a raw stream the bytes after
/// the handshake frame are arbitrary; parsing past the head would either
/// throw on them (a length-looking raw prefix) or mis-parse them into frames
/// whose re-encoding is not byte-identical (JSON key order) — both corrupt
/// the raw handoff. Never parsing past the requested frame removes the whole
/// failure class.
public struct PtxFrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func feed(_ chunk: Data) {
        buffer.append(chunk)
    }

    /// One complete frame from the head of the buffer, or nil if more bytes
    /// are needed. Throws only for a malformed HEAD frame, which on a framed
    /// lane is a real protocol error.
    public mutating func next() throws -> PtxFrame? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length <= PtxProtocol.maxFrameLength else {
            throw PtxFrameError.frameTooLarge(length)
        }
        guard buffer.count >= 4 + length else { return nil }
        let body = Data(buffer.dropFirst(4).prefix(length))
        buffer.removeFirst(4 + length)
        let envelope: PtxFrameEnvelope
        do {
            envelope = try JSONDecoder().decode(PtxFrameEnvelope.self, from: body)
        } catch {
            throw PtxFrameError.malformedJSON
        }
        guard envelope.v == PtxProtocol.version else {
            throw PtxFrameError.unsupportedVersion(envelope.v)
        }
        return PtxFrame(type: envelope.t, payload: envelope.p?.objectValue ?? [:])
    }

    /// Unparsed bytes past the last frame `next()` returned — on a raw stream
    /// these ARE payload, re-injected verbatim ahead of live reads.
    public mutating func drainRemainder() -> Data {
        let remainder = buffer
        buffer = Data()
        return remainder
    }
}
