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
    /// The physical Mac device id pinned by the pair grant. This is kept
    /// separate from `relayObjectID`: multiple tagged app instances can share
    /// one physical Mac without sharing a relay or host leg.
    public let macDeviceID: String
    /// Stable app-instance identity used to address the account-owned relay
    /// object. On both sides this is the Mac's adopted endpoint identity.
    public let relayObjectID: String
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
        relayObjectID: String,
        selfDeviceID: String,
        role: DotLegRole,
        tokenProvider: @escaping @Sendable () async throws -> String,
        journal: DotJournal
    ) {
        self.relayBaseURL = relayBaseURL
        self.macDeviceID = macDeviceID
        self.relayObjectID = relayObjectID
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

    private struct PendingSend {
        let sequence: UInt64
        let destination: UInt32
        let payload: Data
        var sentGeneration: UInt64?
    }

    private var eventStream: AsyncStream<DotLegEvent>?
    private var eventContinuation: AsyncStream<DotLegEvent>.Continuation?
    private var runTask: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var stopped = false
    private var ready = false
    private var generation: UInt64 = 0
    private var legIDValue: UInt32?
    private var resumeKey: String?
    private var authDeadline: Date?
    private var nextSequenceByDestination: [UInt32: UInt64] = [:]
    private var pending: [PendingSend] = []
    private var pendingBytes = 0
    private var lastReceivedBySource: [UInt32: UInt64] = [:]
    private var reconnectAttempt = 0
    private var flushing = false
    private var lastInboundAt: ContinuousClock.Instant?

    private static let maxPendingFrames = 4_096
    private static let maxPendingBytes = 8 * 1024 * 1024

    public init(configuration: DotLegConfiguration) {
        self.configuration = configuration
    }

    /// Start dialing. Events (including all inbound frames) arrive on the
    /// returned stream; exactly one consumer may iterate it.
    public func start() -> AsyncStream<DotLegEvent> {
        if let eventStream { return eventStream }
        let (stream, continuation) = AsyncStream.makeStream(of: DotLegEvent.self)
        eventStream = stream
        eventContinuation = continuation
        stopped = false
        configuration.journal.record(
            component: "leg", event: "started",
            attributes: ["role": configuration.role.rawValue]
        )
        runTask = Task { [weak self] in
            await self?.runLoop()
        }
        return stream
    }

    /// Send one E2E payload to the peer. Host: `destination` = phone leg id.
    /// Phone: destination is ignored (the relay routes uploads to the host).
    public func send(_ payload: Data, to destination: UInt32) async throws {
        guard !stopped else { throw DotTransportError.stopped }
        guard configuration.role == .phone || destination > 0 else {
            throw DotTransportError.protocolViolation("missing destination leg")
        }
        guard payload.count + DotWire.dataHeaderBytes <= DotWire.maxDataFrameBytes else {
            throw DotTransportError.protocolViolation("payload too large")
        }
        guard pending.count < Self.maxPendingFrames,
              pendingBytes + payload.count <= Self.maxPendingBytes else {
            throw DotTransportError.backpressure
        }
        _ = start()
        let key = configuration.role == .phone ? 0 : destination
        let next = (nextSequenceByDestination[key] ?? 0) + 1
        nextSequenceByDestination[key] = next
        pending.append(PendingSend(
            sequence: next,
            destination: destination,
            payload: payload,
            sentGeneration: nil
        ))
        pendingBytes += payload.count
        configuration.journal.record(
            component: "leg", event: "data-queued",
            attributes: [
                "role": configuration.role.rawValue,
                "destination": String(destination),
                "seq": String(next),
                "bytes": String(payload.count),
            ]
        )
        // A send is durable in the local resend queue before it touches the
        // socket. This is what makes a leg drop transparent to its caller.
        await flushPending()
    }

    /// This leg's relay-assigned id (nil until the first hello.ack).
    public var legID: UInt32? {
        legIDValue
    }

    public func stop() async {
        guard !stopped else { return }
        stopped = true
        ready = false
        runTask?.cancel()
        runTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        eventContinuation?.yield(.closed(reason: "stopped"))
        eventContinuation?.finish()
        eventContinuation = nil
    }

    private func runLoop() async {
        configuration.journal.record(
            component: "leg", event: "run-loop-started",
            attributes: ["role": configuration.role.rawValue]
        )
        while !stopped && !Task.isCancelled {
            do {
                try await connectOnce()
                reconnectAttempt = 0
                try await receiveLoop()
            } catch {
                guard !stopped && !Task.isCancelled else { break }
                configuration.journal.record(
                    component: "leg", event: "connect-loop-failed",
                    attributes: [
                        "role": configuration.role.rawValue,
                        "error": String(describing: error),
                    ]
                )
                ready = false
                socket?.cancel(with: .abnormalClosure, reason: nil)
                socket = nil
                eventContinuation?.yield(.suspended(reason: String(describing: error)))
                reconnectAttempt = min(reconnectAttempt + 1, 6)
                let delay = [1, 2, 5, 10, 20, 30, 60][reconnectAttempt]
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func connectOnce() async throws {
        configuration.journal.record(
            component: "leg", event: "connect-start",
            attributes: [
                "role": configuration.role.rawValue,
                "mac": DotJournal.redactedIdentifier(configuration.macDeviceID),
                "relay": DotJournal.redactedIdentifier(configuration.relayObjectID),
            ]
        )
        let token = try await configuration.tokenProvider()
        let wasResuming = resumeKey != nil
        if !wasResuming {
            // A fresh leg gets a new relay id, so inbound coverage starts over.
            // Keep upload sequence numbers monotonic across leg replacement.
            // Resetting this map here races with a caller that queued the
            // client hello immediately after `start()`, which can otherwise
            // reuse sequence 1 for two different frames.
            lastReceivedBySource.removeAll(keepingCapacity: false)
        }
        var components = URLComponents(url: configuration.relayBaseURL, resolvingAgainstBaseURL: false)
        let path = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let endpoint = configuration.role == .host ? "host" : "connect"
        components?.path = "/\(path.isEmpty ? "" : path + "/")v1/relay/\(endpoint)"
        var items = components?.queryItems ?? []
        items.append(URLQueryItem(name: "mac", value: configuration.macDeviceID))
        items.append(URLQueryItem(name: "relay", value: configuration.relayObjectID))
        items.append(URLQueryItem(name: "device", value: configuration.selfDeviceID))
        components?.queryItems = items
        guard let url = components?.url else { throw DotTransportError.invalidURL }
        let wsURL: URL
        if var wsComponents = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            wsComponents.scheme = wsComponents.scheme == "https" ? "wss" : "ws"
            guard let resolved = wsComponents.url else { throw DotTransportError.invalidURL }
            wsURL = resolved
        } else {
            throw DotTransportError.invalidURL
        }

        configuration.journal.record(
            component: "leg", event: "connect-url",
            attributes: [
                "role": configuration.role.rawValue,
                "host": wsURL.host ?? "-",
                "path": wsURL.path,
                "resuming": String(wasResuming),
            ]
        )

        var request = URLRequest(url: wsURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = DotWire.maxDataFrameBytes
        task.resume()
        socket = task
        generation += 1
        let hello = DotControlFrame.hello(
            device: configuration.selfDeviceID,
            resume: resumeKey,
            ack: configuration.role == .phone ? lastReceivedBySource.values.max() : nil,
            acks: configuration.role == .host
                ? Dictionary(uniqueKeysWithValues: lastReceivedBySource.map { ($0.key, $0.value) })
                : nil
        )
        try await task.send(.string(try hello.encoded()))
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await receiveWithDeadline(task, seconds: 15)
        } catch {
            configuration.journal.record(
                component: "leg", event: "connect-failed",
                attributes: ["error": String(describing: error)]
            )
            throw error
        }
        guard case .string(let text) = message else {
            configuration.journal.record(
                component: "leg", event: "connect-failed",
                attributes: ["error": "expected hello.ack"]
            )
            throw DotTransportError.handshakeFailed("expected hello.ack")
        }
        let control = try decodeControl(text)
        let id: UInt32
        let key: String
        let peerOnline: Bool
        let replayed: Int
        switch control {
        case let .helloAck(ackID, resume, _, online, replayCount):
            id = ackID
            key = resume
            peerOnline = online
            replayed = replayCount
        case let .resumeFailed(reason):
            // A dropped leg can outlive the relay's resume proof (for example
            // after a DO restart). Clear the stale key before the next dial,
            // otherwise every retry repeats the refused resume forever.
            resumeKey = nil
            configuration.journal.record(
                component: "leg", event: "resume-failed",
                attributes: ["reason": reason]
            )
            throw DotTransportError.handshakeFailed("resume failed: \(reason)")
        default:
            configuration.journal.record(
                component: "leg", event: "connect-failed",
                attributes: ["error": "expected hello.ack"]
            )
            throw DotTransportError.handshakeFailed("expected hello.ack")
        }
        legIDValue = id
        resumeKey = key
        ready = true
        authDeadline = nil
        eventContinuation?.yield(replayed > 0 ? .resumed(replayedFrames: replayed) : .up(peerOnline: peerOnline))
        configuration.journal.record(
            component: "leg", event: "connected",
            attributes: [
                "leg": String(id),
                "peer_online": String(peerOnline),
                "replayed": String(replayed),
            ]
        )
        await flushPending()
    }

    private func receiveLoop() async throws {
        guard let task = socket else { throw DotTransportError.notConnected }
        configuration.journal.record(
            component: "leg", event: "receive-loop-started",
            attributes: ["role": configuration.role.rawValue]
        )
        lastInboundAt = .now
        let keepaliveInterval = configuration.keepaliveInterval
        let watchdog = Task { [weak self, weak task] in
            guard let task else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(keepaliveInterval))
                } catch {
                    return
                }
                guard let self else { return }
                if await self.keepaliveTick(on: task) { return }
            }
        }
        defer {
            watchdog.cancel()
            lastInboundAt = nil
        }
        while !stopped && !Task.isCancelled {
            let message = try await task.receive()
            lastInboundAt = .now
            try await handle(message)
            if let authDeadline, authDeadline.timeIntervalSinceNow < 90 {
                try await refreshAuth(on: task)
            }
        }
    }

    /// Keep liveness independent from URLSession's receive continuation. A
    /// racing timeout task cannot safely cancel `receive()` without waiting
    /// for URLSession to finish it, which would strand the leg before its
    /// first ping. The watchdog sends pings and owns the read-deadline close.
    private func keepaliveTick(on task: URLSessionWebSocketTask) async -> Bool {
        guard !stopped, socket === task else { return true }
        let lastInbound = lastInboundAt ?? .now
        let elapsed = lastInbound.duration(to: .now)
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        if seconds > configuration.readLivenessDeadline {
            configuration.journal.record(
                component: "leg", event: "read-liveness-expired",
                attributes: ["role": configuration.role.rawValue]
            )
            task.cancel(with: .abnormalClosure, reason: nil)
            return true
        }
        do {
            try await task.send(.string(try DotControlFrame.ping(ts: Date().timeIntervalSince1970).encoded()))
            configuration.journal.record(
                component: "leg", event: "ping-sent",
                attributes: ["role": configuration.role.rawValue]
            )
            if let authDeadline, authDeadline.timeIntervalSinceNow < 90 {
                try await refreshAuth(on: task)
            }
            return false
        } catch {
            configuration.journal.record(
                component: "leg", event: "keepalive-failed",
                attributes: [
                    "role": configuration.role.rawValue,
                    "error": String(describing: error),
                ]
            )
            task.cancel(with: .abnormalClosure, reason: nil)
            return true
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) async throws {
        switch message {
        case .string(let text):
            switch try decodeControl(text) {
            case .pong(let ts):
                configuration.journal.record(
                    component: "leg",
                    event: "pong",
                    attributes: ["ts": String(ts), "path": "do:relay"]
                )
            case .ping(let ts):
                try await socket?.send(.string(try DotControlFrame.pong(ts: ts).encoded()))
            case .ackUp(let sequence, let destination):
                let matches: (PendingSend) -> Bool = { item in
                    guard item.sequence <= sequence else { return false }
                    return self.configuration.role == .phone || item.destination == (destination ?? 0)
                }
                var retained: [PendingSend] = []
                retained.reserveCapacity(pending.count)
                for item in pending {
                    if matches(item) {
                        pendingBytes -= item.payload.count
                    } else {
                        retained.append(item)
                    }
                }
                pending = retained
            case .authOK(let deadline):
                authDeadline = Date(timeIntervalSince1970: deadline / 1000)
            case .resumeFailed(let reason):
                resumeKey = nil
                pending.removeAll(keepingCapacity: false)
                pendingBytes = 0
                lastReceivedBySource.removeAll(keepingCapacity: false)
                eventContinuation?.yield(.reset(reason: reason))
            case .peerOnline(let id, let device):
                eventContinuation?.yield(.peerOnline(legID: id, device: device))
            case .peerOffline(let id, let reason):
                eventContinuation?.yield(.peerOffline(legID: id, reason: reason))
            case .error(let code, let message):
                throw DotTransportError.remote(code + ": " + message)
            case .helloAck, .authRefresh, .ack, .hello:
                break
            }
        case .data(let data):
            guard let frame = DotWire.decodeData(data) else {
                throw DotTransportError.protocolViolation("malformed data frame")
            }
            guard frame.legID > 0 else {
                throw DotTransportError.protocolViolation("missing source leg")
            }
            configuration.journal.record(
                component: "leg", event: "data-received",
                attributes: [
                    "source_leg": String(frame.legID),
                    "seq": String(frame.seq),
                    "bytes": String(frame.payload.count),
                ]
            )
            let previous = lastReceivedBySource[frame.legID] ?? 0
            guard frame.seq > previous else { return }
            lastReceivedBySource[frame.legID] = frame.seq
            eventContinuation?.yield(.frame(sourceLegID: frame.legID, payload: frame.payload))
            let ack = DotControlFrame.ack(seq: frame.seq, leg: configuration.role == .host ? frame.legID : nil)
            try await socket?.send(.string(try ack.encoded()))
        @unknown default:
            break
        }
    }

    private func flushPending() async {
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }
        guard ready, let task = socket, legIDValue != nil else { return }
        var index = 0
        while index < pending.count {
            guard ready, socket === task else { return }
            if pending[index].sentGeneration == generation {
                index += 1
                continue
            }
            let item = pending[index]
            let headerDestination = configuration.role == .phone ? 0 : item.destination
            let frame = DotWire.encodeData(.init(
                legID: headerDestination,
                seq: item.sequence,
                payload: item.payload
            ))
            do {
                try await task.send(.data(frame))
            } catch {
                configuration.journal.record(
                    component: "leg", event: "data-send-failed",
                    attributes: [
                        "role": configuration.role.rawValue,
                        "destination": String(item.destination),
                        "seq": String(item.sequence),
                        "error": String(describing: error),
                    ]
                )
                return
            }
            configuration.journal.record(
                component: "leg", event: "data-sent",
                attributes: [
                    "role": configuration.role.rawValue,
                    "destination": String(item.destination),
                    "seq": String(item.sequence),
                    "bytes": String(item.payload.count),
                ]
            )
            // An ack can prune this item while URLSession is suspended. Find
            // it by both sequence and destination, since host sequences are
            // independent for every phone leg.
            if let sentIndex = pending.firstIndex(where: {
                $0.sequence == item.sequence && $0.destination == item.destination
            }) {
                pending[sentIndex].sentGeneration = generation
                index = sentIndex + 1
            } else if index >= pending.count {
                return
            }
        }
    }

    private func refreshAuth(on task: URLSessionWebSocketTask) async throws {
        let token = try await configuration.tokenProvider()
        try await task.send(.string(try DotControlFrame.authRefresh(token: token).encoded()))
        configuration.journal.record(
            component: "leg",
            event: "auth-refreshed",
            attributes: ["role": configuration.role.rawValue, "path": "do:relay"]
        )
    }

    /// Connect-time hello still needs a bounded wait. The timeout closes the
    /// handshake socket before the task group exits, so URLSession cannot
    /// strand the structured timeout task. Steady-state reads use the
    /// independent watchdog above instead of racing `receive()`.
    private func receiveWithDeadline(
        _ task: URLSessionWebSocketTask,
        seconds: Int
    ) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await task.receive() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                task.cancel(with: .abnormalClosure, reason: nil)
                throw DotReceiveTimeout()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func decodeControl(_ text: String) throws -> DotControlFrame {
        guard let frame = try DotControlFrame.decode(text) else {
            throw DotTransportError.protocolViolation("unknown control frame")
        }
        return frame
    }
}

private struct DotReceiveTimeout: Error {}

public enum DotTransportError: Error, Equatable, Sendable {
    case stopped
    case invalidURL
    case notConnected
    case handshakeFailed(String)
    case protocolViolation(String)
    case readLivenessExpired
    case remote(String)
    case admissionFailed(String)
    case sessionEnded(String)
    case backpressure
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
    let configuration: DotPeerEngineConfiguration
    var state: DotPeerState = .idle
    var stateStream: AsyncStream<DotPeerState>?
    var stateContinuation: AsyncStream<DotPeerState>.Continuation?
    var connectTask: Task<any DotSecureSessionProtocol, any Error>?
    var pumpTask: Task<Void, Never>?
    var currentSession: DotSecureSession?
    var stopped = false

    public init(configuration: DotPeerEngineConfiguration) {
        self.configuration = configuration
    }

    /// Current state plus a stream of transitions (single consumer).
    public func states() -> AsyncStream<DotPeerState> {
        if let stateStream { return stateStream }
        let (stream, continuation) = AsyncStream.makeStream(of: DotPeerState.self)
        stateStream = stream
        stateContinuation = continuation
        continuation.yield(state)
        return stream
    }

    /// Dial now (idempotent while connecting/ready).
    public func connect() async {
        guard !stopped, connectTask == nil else { return }
        if case .ready = state { return }
        setState(.connecting)
        let task = Task<any DotSecureSessionProtocol, any Error> { [weak self] in
            guard let self else { throw DotTransportError.stopped }
            return try await self.establishWithRetry()
        }
        connectTask = task
        do {
            let session = try await task.value
            connectTask = nil
            if let concrete = session as? DotSecureSession { currentSession = concrete }
            setState(.ready(session))
        } catch {
            connectTask = nil
            guard !stopped else { return }
            setState(.closed(reason: String(describing: error)))
        }
    }

    /// A route can become usable shortly after the attach ticket is delivered:
    /// Stack sign-in, broker registration, and the Mac acceptor all complete
    /// independently. Keep that expected launch race inside the single
    /// reconnect owner, otherwise the deferred transport reports an
    /// instantaneous permanent failure and never gets another dial trigger.
    private func establishWithRetry() async throws -> any DotSecureSessionProtocol {
        var delay: Duration = .milliseconds(250)
        var lastError: (any Error)?
        for attempt in 0..<7 {
            do {
                return try await establish()
            } catch let error as DotTransportError {
                guard Self.retryable(error), attempt < 6 else { throw error }
                lastError = error
                configuration.leg.journal.record(
                    component: "session", event: "establish-retry",
                    attributes: [
                        "attempt": String(attempt + 1),
                        "delay": String(describing: delay),
                        "error": String(describing: error),
                    ]
                )
            } catch {
                // Composition errors include the auth coordinator's bounded
                // `timedOut` result and first-contact broker discovery. They
                // are retryable here; protocol/auth denials are represented
                // by DotTransportError and are filtered above.
                guard attempt < 6 else { throw error }
                lastError = error
                configuration.leg.journal.record(
                    component: "session", event: "establish-retry",
                    attributes: [
                        "attempt": String(attempt + 1),
                        "delay": String(describing: delay),
                        "error": String(describing: error),
                    ]
                )
            }
            try await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(8))
        }
        throw lastError ?? DotTransportError.admissionFailed("connection unavailable")
    }

    private static func retryable(_ error: DotTransportError) -> Bool {
        switch error {
        case .stopped, .protocolViolation:
            return false
        case .remote(let message):
            // Relay authorization and capacity denials are definitive for
            // this ticket. A close without an application error is a normal
            // startup race and can be retried.
            return !message.hasPrefix("unauthorized:")
                && !message.hasPrefix("capacity:")
        case .invalidURL, .notConnected, .handshakeFailed, .readLivenessExpired,
             .sessionEnded, .admissionFailed, .backpressure:
            return true
        }
    }

    /// Returns the ready session, dialing if needed, or throws after the
    /// bounded admission deadline.
    public func readySession() async throws -> any DotSecureSessionProtocol {
        if case let .ready(session) = state { return session }
        if connectTask == nil { await connect() }
        if let connectTask { return try await connectTask.value }
        if case let .ready(session) = state { return session }
        throw DotTransportError.admissionFailed("connection unavailable")
    }

    public func shutdown() async {
        guard !stopped else { return }
        stopped = true
        connectTask?.cancel()
        connectTask = nil
        pumpTask?.cancel()
        pumpTask = nil
        if let currentSession { await currentSession.close(reason: "shutdown") }
        currentSession = nil
        setState(.closed(reason: "shutdown"))
        stateContinuation?.finish()
        stateContinuation = nil
    }

    func setState(_ next: DotPeerState) {
        state = next
        stateContinuation?.yield(next)
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
    let configuration: DotSessionAcceptorConfiguration
    var stateStream: AsyncStream<DotAcceptorEvent>?
    var continuation: AsyncStream<DotAcceptorEvent>.Continuation?
    var runTask: Task<Void, Never>?
    var leg: DotLeg?
    var sessions: [String: DotSecureSession] = [:]
    var stopped = false

    public init(configuration: DotSessionAcceptorConfiguration) {
        self.configuration = configuration
    }

    public func start() -> AsyncStream<DotAcceptorEvent> {
        if let stateStream { return stateStream }
        let (stream, continuation) = AsyncStream.makeStream(of: DotAcceptorEvent.self)
        stateStream = stream
        self.continuation = continuation
        stopped = false
        runTask = Task { [weak self] in await self?.runLoop() }
        return stream
    }

    public func stop() async {
        guard !stopped else { return }
        stopped = true
        runTask?.cancel()
        runTask = nil
        if let leg { await leg.stop() }
        leg = nil
        for session in sessions.values { await session.close(reason: "shutdown") }
        sessions.removeAll()
        continuation?.finish()
        continuation = nil
    }

    /// Remove a session after its consumer has finished. The acceptor owns
    /// this table so a long-running Mac cannot retain every historical phone
    /// session until the next process restart.
    public func retire(sessionID: String) {
        sessions[sessionID] = nil
    }
}
