// CmuxDorTransport public API surface.
//
// Layering (bottom → top):
//   DorLeg            one relay WebSocket leg to the ACCOUNT's Durable Object;
//                     transparent resume; sequenced reliable frames.
//   DorSecureSession  one E2E-encrypted, multiplexed session between a phone
//                     and a Mac over a pair of legs (X25519+Ed25519 handshake
//                     bound to the pair grant; ChaChaPoly frames; byte-stream
//                     mux with lane descriptors).
//   DorPeerEngine     (phone) THE single reconnect owner for one Mac peer.
//   DorSessionAcceptor (Mac) admits inbound phone sessions after grant
//                     verification and hands them to the host runtime.

public import Foundation

/// Input safety rules shared by the relay protocol and its diagnostic sink.
/// The relay and the peer are remote boundaries, so their text is never
/// allowed to become an unbounded log line or a control-flow reason.
enum DorSafety {
    static let maxHandshakeBytes = 16 * 1024
    static let maxReasonBytes = 128
    static let maxAttributeBytes = 256

    static func boundedText(_ raw: String?, fallback: String = "") -> String {
        guard let raw else { return fallback }
        var result = String.UnicodeScalarView()
        var bytes = 0
        for scalar in raw.unicodeScalars {
            // Exclude C0/C1 controls and line/paragraph separators. They can
            // forge log records or alter terminal diagnostics.
            guard scalar.value >= 0x20,
                  scalar.value != 0x7F,
                  scalar.value != 0x85,
                  scalar.value != 0x2028,
                  scalar.value != 0x2029
            else { continue }
            let scalarBytes = String(scalar).utf8.count
            guard bytes + scalarBytes <= maxAttributeBytes else { break }
            result.append(scalar)
            bytes += scalarBytes
        }
        return result.isEmpty ? fallback : String(result)
    }

    /// Convert peer-provided reasons to a small, stable vocabulary. A reason
    /// must not carry arbitrary server, filesystem, or exception text.
    static func stableReason(_ raw: String?, fallback: String = "peer-error") -> String {
        guard let raw else { return fallback }
        let value = raw.lowercased()
        switch value {
        case "stopped", "shutdown", "already-ended", "user-close", "test-over",
             "keepalive-timeout", "admit-timeout", "admit-stall", "seal-failed",
             "superseded", "superseded-by-handshake", "unauthorized", "capacity",
             "protocol-error", "protocol-error-retry", "unauthorized-retry",
             "leg-closed", "leg-stream-ended", "leg-reset", "download-sequence-gap",
             "stream-buffer-overflow", "stream-capacity", "invalid-credit", "peer-closed",
             "resume-refused", "unknown-session", "buffer-overflow", "gap-not-provable",
             "invalid-grant", "not-admitted", "sign-failed", "identity-sign-failed",
             "admission-denied", "peer-error", "no-grant":
            return String(value.prefix(maxReasonBytes))
        default:
            return fallback
        }
    }

    static func relayReason(_ raw: String?) -> String {
        switch raw?.lowercased() {
        case "unknown session": return "unknown-session"
        case "buffer overflow": return "buffer-overflow"
        case "gap not provable": return "gap-not-provable"
        default: return "resume-refused"
        }
    }

    /// Protect the journal even when a future call site forgets to classify
    /// an error before recording it.
    static func journalValue(key: String, value: String) -> String {
        let lower = key.lowercased()
        let secretKeys = ["token", "secret", "password", "authorization", "grant", "stderr", "stdout"]
        if secretKeys.contains(where: { lower.contains($0) }) {
            return "[redacted]"
        }
        return boundedText(value, fallback: "-")
    }
}

// MARK: - Identity and trust material (injected by the apps)

/// The device's long-lived Ed25519 identity. Adapted from the existing
/// keychain-backed iroh identity repositories so every pairing/grant issued
/// for the iroh transports keeps working over dor with zero re-pairing.
public protocol DorIdentitySigning: Sendable {
    /// Raw 32-byte Ed25519 public key. Its lowercase hex is the identity the
    /// pair grants pin as `initiator.endpointID` / `acceptor.endpointID`.
    var publicKey: Data { get }
    func sign(_ message: Data) async throws -> Data
}

/// Everything one side needs to authenticate the E2E channel.
public struct DorAdmissionMaterial: Sendable {
    /// Phone side: the broker-signed pair grant (JWS) for this Mac. The host
    /// side leaves it nil (the phone presents, the host verifies).
    public let grantJWS: String?
    /// Pinned Ed25519 grant-verification public keys (raw 32-byte), from the
    /// persisted trust snapshot.
    public let grantVerificationKeys: [Data]
    /// Phone side: the Mac identity public key (raw 32 bytes) the handshake
    /// must terminate at. Host side: nil (any grant-bound phone may connect).
    public let expectedPeerPublicKey: Data?

    public init(grantJWS: String?, grantVerificationKeys: [Data], expectedPeerPublicKey: Data?) {
        self.grantJWS = grantJWS
        self.grantVerificationKeys = grantVerificationKeys
        self.expectedPeerPublicKey = expectedPeerPublicKey
    }
}

/// The peer a session admitted, with the verified grant claims.
public struct DorAdmittedPeer: Sendable {
    public let identityPublicKey: Data
    public let identityHex: String
    public let deviceID: String
    public let platform: String?
    public let tag: String?
    public let bindingID: String?
    public let grantJTI: String?

    public init(
        identityPublicKey: Data,
        deviceID: String,
        platform: String?,
        tag: String?,
        bindingID: String?,
        grantJTI: String?
    ) {
        self.identityPublicKey = identityPublicKey
        self.identityHex = identityPublicKey.lowercaseHex
        self.deviceID = deviceID
        self.platform = platform
        self.tag = tag
        self.bindingID = bindingID
        self.grantJTI = grantJTI
    }
}

// MARK: - Leg

public enum DorLegRole: String, Sendable {
    case host
    case phone
}

public struct DorLegConfiguration: Sendable {
    /// Relay service base (the presence worker origin); ws(s) derived from it.
    public let relayBaseURL: URL
    /// The Mac this leg talks to (or IS): the phone leg's dial target, the
    /// host leg's own device id.
    public let macDeviceID: String
    /// This device's own id (== macDeviceID on the host leg).
    public let selfDeviceID: String
    public let role: DorLegRole
    /// Fresh Stack access token on every (re)dial and for in-band refresh.
    public let tokenProvider: @Sendable () async throws -> String
    public let journal: DorJournal
    /// App-level WS keepalive ping cadence (seconds).
    public var keepaliveInterval: TimeInterval = 20
    /// No inbound traffic for this long ⇒ presume the socket dead and redial
    /// now with resume (read-liveness watchdog).
    public var readLivenessDeadline: TimeInterval = 70
    /// Suspending-vs-continuous clock divergence beyond this per tick ⇒ the
    /// process slept; redial now instead of waiting for read-liveness.
    public var clockJumpThreshold: TimeInterval = 30
    /// In-band auth refresh cadence (seconds). Stack access tokens live
    /// ≥15 min and the relay caps deadlines at 15 min, so 5 min keeps every
    /// leg comfortably inside its deadline forever.
    public var authRefreshInterval: TimeInterval = 300

    public init(
        relayBaseURL: URL,
        macDeviceID: String,
        selfDeviceID: String,
        role: DorLegRole,
        tokenProvider: @escaping @Sendable () async throws -> String,
        journal: DorJournal
    ) {
        self.relayBaseURL = relayBaseURL
        self.macDeviceID = macDeviceID
        self.selfDeviceID = selfDeviceID
        self.role = role
        self.tokenProvider = tokenProvider
        self.journal = journal
    }
}

public enum DorLegEvent: Sendable {
    /// The leg established a fresh session (first hello, or after `.reset`).
    case up(peerOnline: Bool)
    /// The relay reports the peer side came online (host: which leg).
    case peerOnline(legID: UInt32?, device: String?)
    case peerOffline(legID: UInt32?, reason: String?)
    /// The underlying socket dropped; a resume dial is in flight. Data sent
    /// during suspension buffers and flushes on resume.
    case suspended(reason: String)
    /// Resume completed; continuity was preserved (nothing was lost).
    case resumed(replayedFrames: Int)
    /// Resume was refused (relay restarted, ring overflow…): leg continuity
    /// is lost and every E2E session over this leg is dead. The leg
    /// re-establishes as a FRESH leg (new leg id, new streams) and `.up`
    /// follows when it succeeds.
    case reset(reason: String)
    /// Inbound data frame from the peer (payload = E2E bytes).
    case frame(sourceLegID: UInt32, payload: Data)
    /// The leg stopped or failed terminally (auth rejected, superseded,
    /// capacity). No further dialing.
    case closed(reason: String)
}

// MARK: - Secure session (E2E mux)

/// Lane descriptor, first frame on every mux stream.
public struct DorLaneDescriptor: Sendable, Codable, Equatable {
    public let lane: String
    public let resource: String?
    public let cursor: UInt64?
    public let offset: UInt64?

    public init(lane: String, resource: String? = nil, cursor: UInt64? = nil, offset: UInt64? = nil) {
        self.lane = lane
        self.resource = resource
        self.cursor = cursor
        self.offset = offset
    }

    public static let control = DorLaneDescriptor(lane: "control")
    public static let events = DorLaneDescriptor(lane: "events")
    public static func terminal(resource: String, cursor: UInt64?) -> DorLaneDescriptor {
        DorLaneDescriptor(lane: "terminal", resource: resource, cursor: cursor)
    }
    public static func artifact(resource: String, offset: UInt64?) -> DorLaneDescriptor {
        DorLaneDescriptor(lane: "artifact", resource: resource, offset: offset)
    }

    /// Validate untrusted descriptors before they enter the session map or
    /// reach an application router. Unknown lane names remain forward
    /// compatible, but text fields stay bounded and control-free.
    var isValid: Bool {
        guard !lane.isEmpty, lane.utf8.count <= 64,
              DorSafety.boundedText(lane, fallback: "") == lane,
              resource.map({ $0.utf8.count <= 512 && DorSafety.boundedText($0, fallback: "") == $0 }) ?? true
        else { return false }
        return true
    }
}

/// A bidirectional byte stream inside a secure session.
public protocol DorStream: Sendable {
    var descriptor: DorLaneDescriptor { get }
    /// Read the next chunk; nil at orderly end-of-stream.
    func read() async throws -> Data?
    func write(_ data: Data) async throws
    func closeWrite() async
    func close() async
}

public enum DorSessionEvent: Sendable {
    case inboundStream(any DorStream)
    /// The session ended (peer reset, keepalive timeout, leg reset, closed).
    case ended(reason: String)
}

/// One admitted E2E session. Created by `DorPeerEngine` (phone side) or
/// `DorSessionAcceptor` (host side).
public protocol DorSecureSessionProtocol: Sendable {
    var peer: DorAdmittedPeer { get }
    var sessionID: String { get }
    var events: AsyncStream<DorSessionEvent> { get }
    func openStream(_ descriptor: DorLaneDescriptor) async throws -> any DorStream
    func close(reason: String) async
}

// MARK: - Phone side: single reconnect owner

public struct DorPeerEngineConfiguration: Sendable {
    public let leg: DorLegConfiguration
    public let identity: any DorIdentitySigning
    public let admission: DorAdmissionMaterial

    public init(
        leg: DorLegConfiguration,
        identity: any DorIdentitySigning,
        admission: DorAdmissionMaterial
    ) {
        self.leg = leg
        self.identity = identity
        self.admission = admission
    }
}

public enum DorPeerState: Sendable {
    case idle
    case connecting
    case ready(any DorSecureSessionProtocol)
    case closed(reason: String)
}

// MARK: - Host side: session acceptor

public struct DorSessionAcceptorConfiguration: Sendable {
    public let leg: DorLegConfiguration
    public let identity: any DorIdentitySigning
    public let admission: DorAdmissionMaterial
    /// Verified-peer gate beyond grant verification (device allowlists,
    /// same-account policy…). Throw to refuse admission.
    public let judge: @Sendable (DorAdmittedPeer) async throws -> Void

    public init(
        leg: DorLegConfiguration,
        identity: any DorIdentitySigning,
        admission: DorAdmissionMaterial,
        judge: @escaping @Sendable (DorAdmittedPeer) async throws -> Void
    ) {
        self.leg = leg
        self.identity = identity
        self.admission = admission
        self.judge = judge
    }
}

public enum DorAcceptorEvent: Sendable {
    case admitted(any DorSecureSessionProtocol)
    case denied(deviceID: String?, reason: String)
    /// Leg lifecycle worth surfacing (up, suspended, resumed…).
    case legEvent(DorLegEvent)
}
