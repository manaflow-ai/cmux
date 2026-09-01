public import Foundation

/// Wire identity for the irx transport. Distinct from the legacy
/// `cmux/mobile/1` ALPN so an old peer can never half-connect to an irx
/// endpoint: version mismatch fails at the TLS handshake, not mid-protocol.
public enum IrxProtocol {
    public static let alpn = "cmux/irx/1"
    public static var alpnData: Data { Data(alpn.utf8) }
    /// Envelope version carried on every control frame.
    public static let version = 1
    /// Control frames are small (hello/admit/keepalive/descriptors); anything
    /// larger is a protocol error, never buffered.
    public static let maximumControlFrameByteCount = 256 * 1024
    /// Keepalive cadence: one tiny ping per interval, pong deadline after
    /// which the connection is declared dead. Hard closes (the realistic
    /// relay-expiry case) are detected instantly by the termination watcher;
    /// the ping loop bounds SILENT path blackholes to interval + deadline,
    /// keeping worst-case detection-plus-redial inside single-digit seconds.
    public static let keepaliveInterval: Duration = .seconds(5)
    public static let keepaliveDeadline: Duration = .seconds(2)
    /// Consecutive pong misses before the connection is declared dead. One
    /// transient stall (relay hiccup, brief peer pause) must never sever a
    /// healthy session; a re-ping fires immediately after a miss, so real
    /// death still detects in ~strikeLimit x deadline.
    public static let keepaliveStrikeLimit = 2
}

/// Machine-readable close/denial codes. The code travels in the QUIC
/// CONNECTION_CLOSE reason bytes (`irx:<code>`), the single channel for
/// attributed closes: closing WITH the reason is one atomic act, so there is
/// no frame to race against the close.
public enum IrxCloseCode: String, CaseIterable, Sendable {
    // Admission denials (server -> client, terminal for automatic retry).
    case invalidGrant = "invalid-grant"
    case grantExpired = "grant-expired"
    case revoked = "revoked"
    case identityMismatch = "identity-mismatch"
    case malformedHello = "malformed-hello"
    case protocolMismatch = "protocol-mismatch"
    case admissionTimeout = "admission-timeout"
    // Lifecycle closes (either side, auto-redial allowed unless noted).
    case superseded = "superseded"  // terminal: a newer session took over
    case userRequested = "user-requested"  // terminal
    case hostShutdown = "host-shutdown"
    case keepaliveTimeout = "keepalive-timeout"
    case explicitRedial = "explicit-redial"

    /// Codes that must NOT trigger automatic redial.
    public static let terminalForAutoRedial: Set<IrxCloseCode> = [
        .superseded, .userRequested, .invalidGrant, .grantExpired, .revoked,
        .identityMismatch, .malformedHello, .protocolMismatch,
    ]

    static let reasonPrefix = "irx:"

    public var reasonData: Data { Data((Self.reasonPrefix + rawValue).utf8) }

    /// Parses a code back out of a rendered close cause. Longest-first so a
    /// code that is a substring of another can never shadow it.
    public static func parse(fromRenderedCause cause: String) -> IrxCloseCode? {
        let ordered = allCases.sorted { $0.rawValue.count > $1.rawValue.count }
        return ordered.first { cause.contains(reasonPrefix + $0.rawValue) }
    }
}

/// Why a connection ended, with attribution (contractual observability: a
/// close with no attributed cause is a bug, not a logging gap).
public struct IrxTermination: Equatable, Sendable {
    public enum Origin: String, Sendable {
        case local, remote, transport
    }

    public var origin: Origin
    public var code: String

    public init(origin: Origin, code: String) {
        self.origin = origin
        self.code = code
    }
}

/// Application lanes. One lane per QUIC stream; a wedged lane can never stall
/// another. The client opens control/keepalive/terminal/artifact/simulator
/// lanes; the server opens the events lane (unidirectional, server -> client).
public enum IrxLaneKind: String, Codable, Sendable {
    case control
    case keepalive
    case events
    case terminal
    case artifact
    case simulatorStream = "simulator_stream"
}

/// The first frame on every stream: which lane this is, plus lane-specific
/// parameters. After the descriptor (and, for control, the hello/admit
/// exchange), streams carry raw application bytes with no re-framing.
public struct IrxLaneDescriptor: Codable, Equatable, Sendable {
    public var v: Int
    public var lane: IrxLaneKind
    /// Resource identifier, e.g. `terminal:<uuid>` or an artifact path token.
    public var resource: String?
    /// Terminal replay cursor (absolute byte sequence).
    public var cursor: UInt64?
    /// Artifact byte offset.
    public var offset: UInt64?

    public init(
        lane: IrxLaneKind,
        resource: String? = nil,
        cursor: UInt64? = nil,
        offset: UInt64? = nil
    ) {
        v = IrxProtocol.version
        self.lane = lane
        self.resource = resource
        self.cursor = cursor
        self.offset = offset
    }
}

/// Client -> server admission request, first frame on the control stream.
/// List-auth hellos carry NO grant: the server judges the TLS-authenticated
/// key against its device-list snapshot, so admission stays one round trip
/// with no backend call. The grant field remains OPTIONAL on the wire so an
/// old peer's grant-bearing hello still parses (the list judge ignores it).
public struct IrxHello: Codable, Equatable, Sendable {
    public var v: Int
    public var proto: String
    public var grant: String?

    public init(grant: String? = nil) {
        v = IrxProtocol.version
        proto = IrxProtocol.alpn
        self.grant = grant
    }
}

/// Server -> client admission acceptance. Denials have no frame: a denial IS
/// a reasoned connection termination.
public struct IrxAdmit: Codable, Equatable, Sendable {
    public var v: Int
    public var session: String
    /// Milliseconds of lane silence before the client pings.
    public var keepaliveIntervalMs: Int
    /// Milliseconds the client waits for a pong before declaring death.
    public var keepaliveDeadlineMs: Int

    public init(session: String) {
        v = IrxProtocol.version
        self.session = session
        keepaliveIntervalMs = Int(IrxProtocol.keepaliveInterval.components.seconds) * 1000
        keepaliveDeadlineMs = Int(IrxProtocol.keepaliveDeadline.components.seconds) * 1000
    }
}

/// Keepalive lane frames. The reply carries the ping's sequence so stale
/// pongs can never satisfy a newer deadline.
public struct IrxPing: Codable, Equatable, Sendable {
    public var v: Int
    public var seq: UInt64
    public var pong: Bool

    public init(seq: UInt64, pong: Bool) {
        v = IrxProtocol.version
        self.seq = seq
        self.pong = pong
    }
}

/// Server -> client lane rejection, written before finishing the stream so
/// the failure is observable and attributed instead of a bare stream EOF.
public struct IrxLaneError: Codable, Equatable, Sendable {
    public enum Code: Int, Codable, Sendable {
        case unsupportedResource = 2
        case quotaExceeded = 3
        case cursorGap = 4
        case invalidInput = 5
        case streamFailure = 6
    }

    public var v: Int
    public var code: Code
    public var message: String

    public init(code: Code, message: String) {
        v = IrxProtocol.version
        self.code = code
        self.message = message
    }
}

public enum IrxFrameCodecError: Error, Equatable, Sendable {
    case frameTooLarge(Int)
    case malformed
    case unexpectedEOF
    case unsupportedVersion(Int)
}

/// Length-prefixed JSON control frames: 4-byte big-endian length + body.
/// Used only for the tiny control vocabulary above; application lanes carry
/// raw bytes after their descriptor.
public enum IrxFrameCodec {
    public static func encode(_ value: some Encodable) throws -> Data {
        let body = try JSONEncoder().encode(value)
        guard body.count <= IrxProtocol.maximumControlFrameByteCount else {
            throw IrxFrameCodecError.frameTooLarge(body.count)
        }
        var data = Data(capacity: 4 + body.count)
        var length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(body)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from body: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: body)
        } catch {
            throw IrxFrameCodecError.malformed
        }
    }
}
