// CmuxDotTransport public API surface.
//
// CONTRACT FILE: the Mac host runtime (Sources/Mobile) and the iOS
// composition (ios/cmuxPackage) code against these signatures while the
// package internals are implemented. Add API here as needed, but do not
// change existing signatures without updating both consumers.
//
// Layering (bottom → top):
//   DotLeg           one relay WebSocket leg; transparent resume; sequenced
//                    reliable frames to/from peer leg ids.
//   DotSecureSession one E2E-encrypted, multiplexed session between a phone
//                    and the Mac over a pair of legs (X25519+Ed25519 handshake
//                    bound to the pair grant; ChaChaPoly frames; byte-stream
//                    mux with lane descriptors, stream 0 = dialect control).
//   DotPeerEngine    (phone) THE single reconnect owner for one Mac peer.
//   DotSessionAcceptor (Mac) admits inbound phone sessions after grant
//                    verification and hands them to the host runtime.

public import Foundation

// MARK: - Identity and trust material (injected by the apps)

/// The device's long-lived Ed25519 identity. Adapted from the existing
/// keychain-backed iroh identity repositories so every pairing/grant issued
/// for the iroh transports keeps working over dot with zero re-pairing.
public protocol DotIdentitySigning: Sendable {
    /// Raw 32-byte Ed25519 public key. Its lowercase hex is the identity the
    /// pair grants pin as `initiator.endpointID` / `acceptor.endpointID`.
    var publicKey: Data { get }
    func sign(_ message: Data) async throws -> Data
}

/// Everything a side needs to authenticate the E2E channel.
public struct DotAdmissionMaterial: Sendable {
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
public struct DotAdmittedPeer: Sendable {
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
        self.identityHex = identityPublicKey.map { String(format: "%02x", $0) }.joined()
        self.deviceID = deviceID
        self.platform = platform
        self.tag = tag
        self.bindingID = bindingID
        self.grantJTI = grantJTI
    }
}

// MARK: - Leg

public enum DotLegRole: String, Sendable {
    case host
    case phone
}

public struct DotLegConfiguration: Sendable {
    /// Relay service base (the presence worker origin); ws(s) derived from it.
    public let relayBaseURL: URL
    /// The Mac device id the relay object is named for.
    public let macDeviceID: String
    /// This device's own id (== macDeviceID on the host leg).
    public let selfDeviceID: String
    public let role: DotLegRole
    /// Fresh Stack access token on every (re)dial and for in-band refresh.
    public let tokenProvider: @Sendable () async throws -> String
    public let journal: DotJournal
    /// WS-level keepalive ping cadence (seconds).
    public var keepaliveInterval: TimeInterval = 20
    /// No inbound traffic for this long ⇒ presume the socket dead and redial
    /// now with resume (read-liveness watchdog, chatmux-relay lineage).
    public var readLivenessDeadline: TimeInterval = 70
    /// Wall-vs-monotonic divergence beyond this ⇒ host slept; redial now.
    public var clockJumpThreshold: TimeInterval = 30

    public init(
        relayBaseURL: URL,
        macDeviceID: String,
        selfDeviceID: String,
        role: DotLegRole,
        tokenProvider: @escaping @Sendable () async throws -> String,
        journal: DotJournal
    ) {
        self.relayBaseURL = relayBaseURL
        self.macDeviceID = macDeviceID
        self.selfDeviceID = selfDeviceID
        self.role = role
        self.tokenProvider = tokenProvider
        self.journal = journal
    }
}

public enum DotLegEvent: Sendable {
    /// The leg is up (first hello.ack or after an invisible resume).
    case up(peerOnline: Bool)
    /// The relay reports the peer side came online (host: includes which leg).
    case peerOnline(legID: UInt32?, device: String?)
    case peerOffline(legID: UInt32?, reason: String?)
    /// The underlying socket dropped; a resume dial is in flight. Data sent
    /// during suspension is buffered and flushed on resume.
    case suspended(reason: String)
    /// Resume completed; the session continuity was preserved.
    case resumed(replayedFrames: Int)
    /// Resume was refused (relay restarted mid-flight, buffer overflow, …):
    /// leg-level continuity is lost and every session over this leg is dead.
    /// The leg re-establishes as a FRESH leg (new leg id, new streams).
    case reset(reason: String)
    /// Inbound data frame from the peer (payload = E2E ciphertext).
    case frame(sourceLegID: UInt32, payload: Data)
    /// The leg was stopped or failed terminally (auth rejected, capacity).
    case closed(reason: String)
}

/// One relay WebSocket leg. Owns: dial + hello, transparent resume with
/// upload resend buffering (pruned on ackup) and download ack emission,
/// WS keepalive pings, read-liveness + clock-jump watchdogs, in-band
/// auth refresh ahead of the deadline.
///
/// Reliability contract for callers: `send` never fails while the leg is
/// logically alive (frames buffer across suspensions); ordering per
/// destination is preserved; duplicates are dropped internally on resume
/// overlap; a `.reset` event is the ONLY loss signal.
public actor DotLeg {
    public let configuration: DotLegConfiguration

    public init(configuration: DotLegConfiguration) {
        self.configuration = configuration
    }

    /// Start dialing. Events (including all inbound frames) arrive on the
    /// returned stream; exactly one consumer may iterate it.
    public func start() -> AsyncStream<DotLegEvent> {
        fatalError("DotLeg.start: unimplemented (S1)")
    }

    /// Send one E2E payload to the peer. Host: `destination` = phone leg id.
    /// Phone: destination is ignored (the relay routes uploads to the host).
    public func send(_ payload: Data, to destination: UInt32) async throws {
        fatalError("DotLeg.send: unimplemented (S1)")
    }

    /// This leg's relay-assigned id (nil until the first hello.ack).
    public var legID: UInt32? {
        fatalError("DotLeg.legID: unimplemented (S1)")
    }

    public func stop() async {
        fatalError("DotLeg.stop: unimplemented (S1)")
    }
}

// MARK: - Secure session (E2E mux)

/// Lane descriptor, first frame on every mux stream (IrxLaneDescriptor shape).
public struct DotLaneDescriptor: Sendable, Codable, Equatable {
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

    public static let control = DotLaneDescriptor(lane: "control")
    public static func terminal(resource: String, cursor: UInt64?) -> DotLaneDescriptor {
        DotLaneDescriptor(lane: "terminal", resource: resource, cursor: cursor)
    }
    public static let events = DotLaneDescriptor(lane: "events")
    public static func artifact(resource: String, offset: UInt64?) -> DotLaneDescriptor {
        DotLaneDescriptor(lane: "artifact", resource: resource, offset: offset)
    }
}

/// A bidirectional byte stream inside a secure session. Adapts directly to
/// `CmxByteTransport` (control) and the lane-stream seams.
public protocol DotStream: Sendable {
    var descriptor: DotLaneDescriptor { get }
    /// Read the next chunk; nil at orderly end-of-stream.
    func read() async throws -> Data?
    func write(_ data: Data) async throws
    func closeWrite() async
    func close() async
}

public enum DotSessionEvent: Sendable {
    case inboundStream(any DotStream)
    /// The session ended (peer reset, keepalive timeout, leg reset, closed).
    case ended(reason: String)
}

/// One admitted E2E session. Created by `DotPeerEngine` (phone side) or
/// `DotSessionAcceptor` (host side).
public protocol DotSecureSessionProtocol: Sendable {
    var peer: DotAdmittedPeer { get }
    var sessionID: String { get }
    var events: AsyncStream<DotSessionEvent> { get }
    func openStream(_ descriptor: DotLaneDescriptor) async throws -> any DotStream
    func close(reason: String) async
}

// MARK: - Phone side: single reconnect owner

public struct DotPeerEngineConfiguration: Sendable {
    public let leg: DotLegConfiguration
    public let identity: any DotIdentitySigning
    public let admission: DotAdmissionMaterial

    public init(
        leg: DotLegConfiguration,
        identity: any DotIdentitySigning,
        admission: DotAdmissionMaterial
    ) {
        self.leg = leg
        self.identity = identity
        self.admission = admission
    }
}

public enum DotPeerState: Sendable {
    case idle
    case connecting
    case ready(any DotSecureSessionProtocol)
    case closed(reason: String)
}

/// THE single reconnect owner for one Mac peer (IrxPeerEngine lineage).
/// Leg blips resolve below this layer (transparent resume); this engine only
/// redials when the session itself dies (host restart, leg reset, denial).
public actor DotPeerEngine {
    public init(configuration: DotPeerEngineConfiguration) {
        fatalError("DotPeerEngine.init: unimplemented (S1)")
    }

    /// Current state plus a stream of transitions (single consumer).
    public func states() -> AsyncStream<DotPeerState> {
        fatalError("DotPeerEngine.states: unimplemented (S1)")
    }

    /// Dial now (idempotent while connecting/ready).
    public func connect() async {
        fatalError("DotPeerEngine.connect: unimplemented (S1)")
    }

    /// Returns the ready session, dialing if needed, or throws after the
    /// bounded admission deadline.
    public func readySession() async throws -> any DotSecureSessionProtocol {
        fatalError("DotPeerEngine.readySession: unimplemented (S1)")
    }

    public func shutdown() async {
        fatalError("DotPeerEngine.shutdown: unimplemented (S1)")
    }
}

// MARK: - Host side: session acceptor

public struct DotSessionAcceptorConfiguration: Sendable {
    public let leg: DotLegConfiguration
    public let identity: any DotIdentitySigning
    public let admission: DotAdmissionMaterial
    /// Verified-peer gate beyond grant verification (device allowlists,
    /// same-account policy…). Throw to refuse admission.
    public let judge: @Sendable (DotAdmittedPeer) async throws -> Void

    public init(
        leg: DotLegConfiguration,
        identity: any DotIdentitySigning,
        admission: DotAdmissionMaterial,
        judge: @escaping @Sendable (DotAdmittedPeer) async throws -> Void
    ) {
        self.leg = leg
        self.identity = identity
        self.admission = admission
        self.judge = judge
    }
}

public enum DotAcceptorEvent: Sendable {
    case admitted(any DotSecureSessionProtocol)
    case denied(deviceID: String?, reason: String)
    /// Leg lifecycle worth journaling/surfacing (up, suspended, resumed…).
    case legEvent(DotLegEvent)
}

/// Mac-side acceptor: runs the host leg, answers phone handshakes, verifies
/// grants, and emits admitted sessions.
public actor DotSessionAcceptor {
    public init(configuration: DotSessionAcceptorConfiguration) {
        fatalError("DotSessionAcceptor.init: unimplemented (S1)")
    }

    public func start() -> AsyncStream<DotAcceptorEvent> {
        fatalError("DotSessionAcceptor.start: unimplemented (S1)")
    }

    public func stop() async {
        fatalError("DotSessionAcceptor.stop: unimplemented (S1)")
    }
}
