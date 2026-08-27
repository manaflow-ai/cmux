import CMUXMobileCore
import CmuxAuthRuntime
import CmuxDotTransport
import CmuxIrohTransport
import CmuxIrxTransport
import CryptoKit
import Foundation
import OSLog

/// macOS composition root for the dot transport (the Durable Object relay
/// implementation in `CmuxDotTransport`). Default-on: when the gate is on,
/// this runtime owns the app's mobile transport slot, and neither the irx
/// runtime nor the legacy iroh endpoint is started — the Mac serves the full
/// mobile dialect to admitted phone sessions over one standing relay leg.
@MainActor
final class MobileHostDotRuntime {
    static let shared = MobileHostDotRuntime()

    nonisolated static let enabledDefaultsKey = "cmux.dot.enabled"

    /// dot is the PRIMARY transport: on by default in every configuration.
    /// An explicit `false` in defaults (the remote revert switch writes it)
    /// falls back to the irx/legacy pick; the env var re-arms and persists.
    nonisolated static var isEnabled: Bool {
        if ProcessInfo.processInfo.environment["CMUX_DOT_ENABLED"] == "1" {
            UserDefaults.standard.set(true, forKey: enabledDefaultsKey)
            return true
        }
        if UserDefaults.standard.object(forKey: enabledDefaultsKey) != nil {
            return UserDefaults.standard.bool(forKey: enabledDefaultsKey)
        }
        return true
    }

    /// Why the gate is off, for the composition-root log line. `nil` while
    /// enabled; the only way to disable is an explicit `false` default.
    nonisolated static var forceDisabledReason: String? {
        if ProcessInfo.processInfo.environment["CMUX_DOT_ENABLED"] == "1" {
            return nil
        }
        guard UserDefaults.standard.object(forKey: enabledDefaultsKey) != nil,
            !UserDefaults.standard.bool(forKey: enabledDefaultsKey)
        else { return nil }
        return "defaults \(enabledDefaultsKey)=false"
    }

    /// One journal for every dot component on the Mac. The soak analyzer
    /// tails the JSONL file; every line mirrors to os_log at notice level so
    /// `log show` sees it too.
    nonisolated static let journal: DotJournal = {
        let tag = MobileHostIdentity.instanceTag()
        let logger = Logger(subsystem: "dev.cmux", category: "dot-host")
        return DotJournal.file(
            url: URL(fileURLWithPath: "/tmp/cmux-dot-journal-mac-\(tag).jsonl"),
            mirror: { line in logger.notice("\(line, privacy: .public)") }
        )
    }()

    /// The proven terminal-lane server takes the irx journal type. Give it an
    /// os_log-only instance in the dot category: the dot JSONL file keeps
    /// exactly one writer (``journal``'s serial queue), so lane-internal
    /// events land in `log show` instead of interleaving a second file handle.
    nonisolated static let laneServerJournal = IrxJournal(
        subsystem: "dev.cmux",
        category: "dot-host"
    )

    private weak var auth: AuthCoordinator?
    private var authObservationTask: Task<Void, Never>?
    private var activeAccountID: String?
    private var activationTask: Task<Void, Never>?
    /// Changes on every (de)activation; per-connection supervisors compare it.
    private var generationToken = UUID()

    private var acceptor: DotSessionAcceptor?
    private var acceptLoop: Task<Void, Never>?
    /// Broker HTTP client (plain HTTPS, no iroh networking): keeps this Mac's
    /// binding registered so pairing can mint grants for it, and refreshes
    /// the persisted trust snapshot admission reads. Retained so its token
    /// source and caches live for the activation.
    private var brokerService: IrxBrokerService?

    func configure(auth: AuthCoordinator) {
        self.auth = auth
        Self.journal.record(component: "host-runtime", event: "configured")
        authObservationTask?.cancel()
        authObservationTask = Task { @MainActor [weak self] in
            await auth.awaitBootstrapped()
            guard !Task.isCancelled else { return }
            while !Task.isCancelled {
                let accountID = auth.currentUser?.id
                if accountID != self?.activeAccountID {
                    await self?.transition(to: accountID)
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func transition(to accountID: String?) async {
        guard accountID != activeAccountID else { return }
        await deactivate()
        activeAccountID = accountID
        guard let accountID else { return }
        Self.journal.record(
            component: "host-runtime", event: "activating",
            attributes: ["account": accountID]
        )
        activationTask = Task { @MainActor [weak self] in
            await self?.activate(accountID: accountID)
        }
    }

    private func activate(accountID: String) async {
        guard let auth else { return }
        generationToken = UUID()
        let token = generationToken
        let tag = MobileHostIrohRuntime.currentTag()
        // The relay DO lives on the SAME presence worker origin; the env
        // override (CMUX_PRESENCE_BASE_URL) is respected via this resolver.
        guard let relayBaseURL = PresenceHeartbeatClient.resolvedServiceURL() else {
            Self.journal.record(
                component: "host-runtime", event: "activation-failed",
                attributes: ["reason": "environment"]
            )
            return
        }
        do {
            // IDENTITY ADOPTION: reuse the legacy stack's identity and device
            // ID exactly like the irx runtime, so the Ed25519 public key the
            // dot handshake authenticates equals the EndpointID every
            // existing pair grant pins (refresh-in-place; stored routes on
            // phones keep working with zero re-pairing). This deviceID is the
            // one broker registration binds — the same value that appears as
            // `acceptor.deviceID` in grants — and it names the relay DO.
            let legacy = MobileHostIrohRuntime.shared
            let appInstanceID = try await legacy.appInstances.appInstanceID(
                accountID: accountID, tag: tag)
            let material = try await legacy.identities.identity(
                accountID: accountID, appInstanceID: appInstanceID)
            let deviceID = cmxCanonicalDeviceID(MobileHostIdentity.deviceID())
            let signer = try MobileHostDotIdentitySigner(
                privateKeyData: material.secretKey.bytes)

            // BROKER REGISTRATION (plain HTTPS, no iroh networking): without
            // it a fresh install has no binding for pairing to mint grants
            // against and no trust snapshot for admission to verify them
            // with. Registration FIRST — non-legacy namespaces 403 every
            // other broker call until the binding authorization exists.
            var registrationError: (any Error)?
            if let brokerBaseURL = AuthEnvironment.irohBrokerBaseURL,
                let namespace = CmxIrohMacBundleNamespace(
                    bundleIdentifier: Bundle.main.bundleIdentifier)
            {
                let stateDir = FileManager.default.urls(
                    for: .applicationSupportDirectory, in: .userDomainMask
                )[0].appendingPathComponent("cmux-irx", isDirectory: true)
                do {
                    let identity = IrxIdentity(
                        privateKeyData: material.secretKey.bytes,
                        deviceID: deviceID,
                        appInstanceID: appInstanceID
                    )
                    let broker = try IrxBrokerService(
                        configuration: .init(
                            baseURL: brokerBaseURL,
                            clientNamespace: namespace.rawValue,
                            tag: tag,
                            platform: .mac,
                            displayName: Host.current().localizedName,
                            cacheDirectory: stateDir,
                            identityGeneration: material.generation
                        ),
                        identity: identity,
                        accessTokenPair: { [weak auth] in
                            guard let auth else { return nil }
                            let session = try await auth.authenticatedSessionSnapshot()
                            return (session.accessToken, session.refreshToken)
                        },
                        journal: Self.laneServerJournal
                    )
                    _ = try await broker.register(pairingEnabled: true, relayURLHint: nil)
                    _ = try? await broker.discover()
                    brokerService = broker
                    Self.journal.record(component: "host-runtime", event: "broker-registered")
                } catch {
                    registrationError = error
                    Self.journal.record(
                        component: "host-runtime", event: "broker-registration-failed",
                        attributes: ["reason": String(describing: error)]
                    )
                }
            } else {
                Self.journal.record(
                    component: "host-runtime", event: "broker-registration-skipped",
                    attributes: ["reason": "environment"]
                )
            }

            // Admission reads the persisted trust snapshot synchronously; it
            // never awaits the broker (steady-state independence, same
            // snapshot the irx grant judge reads). Registration above just
            // refreshed it when reachable.
            let trust = IrxDiskCacheTrustReader.read()
            let verificationKeys = Self.grantVerificationKeys(from: trust)
            if verificationKeys.isEmpty {
                Self.journal.record(
                    component: "host-runtime", event: "trust-snapshot-missing",
                    attributes: ["effect": "admissions-fail-closed"]
                )
                // No cached trust AND registration failed: nothing can admit.
                // Throw into the bounded retry ladder instead of parking a
                // fail-closed acceptor.
                if let registrationError { throw registrationError }
            }
            let admission = DotAdmissionMaterial(
                grantJWS: nil,
                grantVerificationKeys: verificationKeys,
                expectedPeerPublicKey: nil
            )
            let legConfiguration = DotLegConfiguration(
                relayBaseURL: relayBaseURL,
                macDeviceID: deviceID,
                selfDeviceID: deviceID,
                role: .host,
                tokenProvider: { [weak auth] in
                    guard let auth else {
                        throw MobileHostDotRuntimeError.signedOut
                    }
                    return try await auth.currentTokens().accessToken
                },
                journal: Self.journal
            )
            let acceptor = DotSessionAcceptor(
                configuration: DotSessionAcceptorConfiguration(
                    leg: legConfiguration,
                    identity: signer,
                    admission: admission,
                    judge: { _ in
                        // Grant verification (signature, tuple pinning,
                        // expiry) happens inside the acceptor against the
                        // pinned keys, and the relay admits only
                        // same-account Stack tokens. No additional
                        // host-side policy yet.
                    }
                )
            )
            self.acceptor = acceptor

            guard generationToken == token else { return }
            publishRoute(identityHex: signer.identityHex)
            startAcceptLoop(acceptor: acceptor, token: token)
            Self.journal.record(
                component: "host-runtime", event: "active",
                attributes: [
                    "identity": signer.identityHex,
                    "device": deviceID,
                    "tag": tag,
                    "relay": relayBaseURL.absoluteString,
                ]
            )
        } catch {
            Self.journal.record(
                component: "host-runtime", event: "activation-failed",
                attributes: ["reason": String(describing: error)]
            )
            // One bounded retry ladder, reset by the auth observation loop on
            // account change: retry activation after 5s while still desired.
            try? await Task.sleep(for: .seconds(5))
            if generationToken == token, activeAccountID == accountID {
                await activate(accountID: accountID)
            }
        }
    }

    private func deactivate() async {
        generationToken = UUID()
        acceptLoop?.cancel()
        acceptLoop = nil
        activationTask?.cancel()
        activationTask = nil
        if let acceptor {
            await acceptor.stop()
        }
        acceptor = nil
        brokerService = nil
        if Self.isEnabled {
            MobileHostPublicStatusCache.update(irohIdentity: nil)
        }
        Self.journal.record(component: "host-runtime", event: "deactivated")
    }

    /// Publishes the adopted identity as THE iroh-identity route, exactly as
    /// irx does, so attach tickets, host status, and presence stay valid and
    /// phones keep resolving this Mac by identity. Identity-only (no path
    /// hints): irx derives its relay hint from a live iroh endpoint's home
    /// relay, which dot deliberately never starts — the dot phone side
    /// resolves by identity + grant and dials the relay DO by device id.
    private func publishRoute(identityHex: String) {
        guard let peerIdentity = try? CmxIrohPeerIdentity(endpointID: identityHex)
        else { return }
        MobileHostPublicStatusCache.update(irohIdentity: peerIdentity, pathHints: [])
        Self.journal.record(
            component: "host-runtime", event: "route-published",
            attributes: ["hints": "0"]
        )
    }

    private func startAcceptLoop(acceptor: DotSessionAcceptor, token: UUID) {
        let journal = Self.journal
        acceptLoop = Task { [weak self] in
            journal.record(component: "host-runtime", event: "accept-loop-started")
            let events = await acceptor.start()
            for await event in events {
                guard !Task.isCancelled else { return }
                switch event {
                case .admitted(let session):
                    journal.record(
                        component: "host-runtime", event: "connection-admitted",
                        attributes: [
                            "session": session.sessionID,
                            "device": session.peer.deviceID,
                        ]
                    )
                    Task { [weak self] in
                        await self?.superviseSession(session, token: token)
                    }
                case .denied(let deviceID, let reason):
                    journal.record(
                        component: "host-runtime", event: "admission-denied",
                        attributes: ["device": deviceID ?? "-", "reason": reason]
                    )
                case .legEvent(let legEvent):
                    // The leg journals its own lifecycle; surface the
                    // steady-state signal the soak analyzer keys on.
                    if case .up(let peerOnline) = legEvent {
                        journal.record(
                            component: "host-runtime", event: "online",
                            attributes: ["peer_online": String(peerOnline)]
                        )
                    }
                }
            }
        }
    }

    private func superviseSession(
        _ session: any DotSecureSessionProtocol,
        token: UUID
    ) async {
        let journal = Self.journal
        let admittedPeer: CmxIrohAdmittedPeer
        do {
            admittedPeer = try Self.admittedPeer(for: session.peer)
        } catch {
            journal.record(
                component: "host-runtime", event: "connection-exit",
                attributes: [
                    "session": session.sessionID,
                    "reason": "identity-mismatch",
                ]
            )
            await session.close(reason: "identity_mismatch")
            return
        }

        let artifactRegistry = MobileHostIrohArtifactTransferRegistry()
        let eventWriter = MobileHostDotEventWriter(session: session, journal: journal)
        let rendezvous = MobileHostDotControlRendezvous()
        // Single consumer of session.events: hands the phone-opened control
        // stream to the rendezvous, then dispatches every later lane stream.
        let lanePump = Task {
            await Self.runLanePump(
                session: session,
                rendezvous: rendezvous,
                admittedPeer: admittedPeer,
                artifactRegistry: artifactRegistry,
                journal: journal
            )
        }
        // The PHONE opens the control stream (initiator, lane "control").
        // No timer here: if it never arrives, the session's own end
        // (keepalive timeout, leg reset) cancels the wait via the pump.
        guard let control = await rendezvous.wait() else {
            journal.record(
                component: "host-runtime", event: "connection-exit",
                attributes: [
                    "session": session.sessionID,
                    "reason": "no-control-stream",
                ]
            )
            lanePump.cancel()
            await eventWriter.close()
            await session.close(reason: "no_control_stream")
            return
        }
        let controlTransport = MobileHostDotControlByteTransport(stream: control)
        let exit = await MobileHostService.acceptTransport(
            controlTransport,
            authorization: .irohAdmission(admittedPeer),
            artifactTransfers: artifactRegistry,
            independentEventWriter: eventWriter,
            isCurrent: { [weak self] in
                let runtime = self
                return await MainActor.run { runtime?.generationToken == token }
            }
        )
        journal.record(
            component: "host-runtime", event: "connection-exit",
            attributes: [
                "session": session.sessionID,
                "lifecycle": String(describing: exit.lifecycle),
                "failure": String(describing: exit.failure),
            ]
        )
        lanePump.cancel()
        await eventWriter.close()
        await session.close(reason: "host_connection_exit")
    }

    /// Post-admission lane dispatch: terminal streams over the byte tee,
    /// artifact reads. Quotas mirror the irx lane loop (4 terminal lanes).
    private nonisolated static func runLanePump(
        session: any DotSecureSessionProtocol,
        rendezvous: MobileHostDotControlRendezvous,
        admittedPeer: CmxIrohAdmittedPeer,
        artifactRegistry: MobileHostIrohArtifactTransferRegistry,
        journal: DotJournal
    ) async {
        var terminalLaneCount = 0
        for await event in session.events {
            if Task.isCancelled { break }
            switch event {
            case .inboundStream(let stream):
                if stream.descriptor.lane == "control",
                    await rendezvous.offer(stream)
                {
                    continue
                }
                journal.record(
                    component: "host-lanes", event: "lane-accepted",
                    attributes: [
                        "lane": stream.descriptor.lane,
                        "resource": stream.descriptor.resource ?? "-",
                    ]
                )
                switch stream.descriptor.lane {
                case "terminal":
                    guard terminalLaneCount < 4 else {
                        await stream.close()
                        continue
                    }
                    terminalLaneCount += 1
                    let resource = stream.descriptor.resource ?? ""
                    let cursor = stream.descriptor.cursor
                    Task {
                        await MobileHostIrxTerminalLaneServer.serve(
                            resourceID: resource,
                            cursor: cursor,
                            stream: Self.bidirectionalStream(stream),
                            journal: Self.laneServerJournal
                        )
                    }
                case "artifact":
                    guard
                        let resource = try? CmxIrohResourceID(
                            stream.descriptor.resource ?? "")
                    else {
                        await stream.close()
                        continue
                    }
                    let offset = stream.descriptor.offset ?? 0
                    Task {
                        let handler = MobileHostIrohArtifactLaneHandler(
                            registry: artifactRegistry)
                        _ = await handler.handleArtifactLane(
                            resourceID: resource,
                            offset: offset,
                            stream: Self.bidirectionalStream(stream),
                            peer: admittedPeer
                        )
                    }
                default:
                    // control arrives exactly once (rendezvous above); events
                    // is host-opened; anything else is unknown.
                    await stream.close()
                }
            case .ended(let reason):
                journal.record(
                    component: "host-runtime", event: "session-ended",
                    attributes: ["session": session.sessionID, "reason": reason]
                )
                await rendezvous.cancel()
            }
        }
        await rendezvous.cancel()
    }

    /// Maps the verified dot peer onto the admitted-peer value the
    /// `acceptTransport` authorization context expects, mirroring how the
    /// irx runtime rebuilds `CmxIrohAdmittedPeer` from its admission claims.
    private nonisolated static func admittedPeer(
        for peer: DotAdmittedPeer
    ) throws -> CmxIrohAdmittedPeer {
        CmxIrohAdmittedPeer(
            peer: CmxIrohGrantPeer(
                // Grants carry the phone's binding id; a missing one falls
                // back to a per-device key so connection grouping (reconnect
                // retirement, per-binding quota) stays scoped to that phone.
                bindingID: peer.bindingID ?? "dot-device:\(peer.deviceID)",
                deviceID: peer.deviceID,
                tag: peer.tag ?? "",
                platform: CmxIrohPlatform(rawValue: peer.platform ?? "") ?? .ios,
                endpointID: try CmxIrohPeerIdentity(endpointID: peer.identityHex),
                identityGeneration: 1
            )
        )
    }

    /// Raw 32-byte Ed25519 keys from the persisted trust snapshot's SPKI DER
    /// entries (fixed 12-byte Ed25519 SPKI prefix + 32 key bytes), the same
    /// parse `CmxIrohGrantVerifier` performs.
    private nonisolated static func grantVerificationKeys(
        from snapshot: IrxTrustSnapshot?
    ) -> [Data] {
        guard let snapshot else { return [] }
        let spkiPrefix = Data([
            0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00,
        ])
        return snapshot.verificationKeys.keys.compactMap { key in
            guard key.alg == "EdDSA",
                let der = Data(base64Encoded: key.spkiDerBase64),
                der.count == spkiPrefix.count + 32,
                der.prefix(spkiPrefix.count) == spkiPrefix
            else { return nil }
            return Data(der.suffix(32))
        }
    }

    private nonisolated static func bidirectionalStream(
        _ stream: any DotStream
    ) -> CmxIrohBidirectionalStream {
        CmxIrohBidirectionalStream(
            receiveStream: MobileHostDotReceiveStreamAdapter(stream: stream),
            sendStream: MobileHostDotSendStreamAdapter(stream: stream)
        )
    }
}

enum MobileHostDotRuntimeError: Error {
    case signedOut
}

/// `DotIdentitySigning` over the adopted keychain identity's Ed25519 seed:
/// the same key that IS the iroh EndpointID, so every existing pair grant
/// (pinned to its lowercase hex) keeps working over dot.
struct MobileHostDotIdentitySigner: DotIdentitySigning {
    let publicKey: Data
    private let privateKeyData: Data

    init(privateKeyData: Data) throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
        self.privateKeyData = privateKeyData
        self.publicKey = key.publicKey.rawRepresentation
    }

    var identityHex: String {
        publicKey.map { String(format: "%02x", $0) }.joined()
    }

    func sign(_ message: Data) async throws -> Data {
        try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
            .signature(for: message)
    }
}

/// Hands the phone-opened control stream from the session's single event
/// consumer (the lane pump) to the supervisor awaiting it. No timers: a
/// session that never opens control is torn down by its own end event, which
/// cancels the wait.
actor MobileHostDotControlRendezvous {
    private enum State {
        case waiting
        case delivered
        case cancelled
    }

    private var pending: (any DotStream)?
    private var waiter: CheckedContinuation<(any DotStream)?, Never>?
    private var state: State = .waiting

    /// Returns true when the stream was accepted as THE control stream.
    func offer(_ stream: any DotStream) -> Bool {
        guard state == .waiting, pending == nil else { return false }
        if let waiter {
            self.waiter = nil
            state = .delivered
            waiter.resume(returning: stream)
        } else {
            pending = stream
        }
        return true
    }

    func cancel() {
        guard state == .waiting else { return }
        state = .cancelled
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func wait() async -> (any DotStream)? {
        if let pending {
            self.pending = nil
            state = .delivered
            return pending
        }
        guard state == .waiting else { return nil }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }
}

/// The admitted control stream as a `CmxByteTransport` — the seam
/// `MobileHostService.acceptTransport` consumes. Raw passthrough of the
/// mobile dialect frames; `connect` is a no-op because the phone already
/// opened the stream. Mirrors `IrxControlByteTransport`'s host role.
struct MobileHostDotControlByteTransport: CmxByteTransport {
    let stream: any DotStream

    func connect() async throws {}

    func receive() async throws -> Data? {
        try await stream.read()
    }

    func send(_ data: Data) async throws {
        try await stream.write(data)
    }

    func close() async {
        await stream.close()
    }
}

/// Adapts one dot lane stream to the readable iroh stream half the proven
/// lane servers (`MobileHostIrxTerminalLaneServer`, the artifact handler)
/// consume. Reads re-chunk to honor the `maximumByteCount` contract;
/// `stop` maps to closing the dot stream (the mux has no per-direction
/// application error codes).
actor MobileHostDotReceiveStreamAdapter: CmxIrohReceiveStream {
    private let stream: any DotStream
    private var buffer = Data()
    private var finished = false

    init(stream: any DotStream) {
        self.stream = stream
    }

    func receive(maximumByteCount: Int) async throws -> Data? {
        guard maximumByteCount > 0 else { return Data() }
        while buffer.isEmpty {
            if finished { return nil }
            guard let chunk = try await stream.read() else {
                finished = true
                return nil
            }
            buffer = chunk
        }
        let taken = Data(buffer.prefix(maximumByteCount))
        buffer.removeFirst(taken.count)
        return taken
    }

    func stop(errorCode: UInt64) async {
        await stream.close()
    }
}

/// The writable half of the same adapter. `reset` maps to a full close;
/// `setPriority` is a no-op because relay legs have no QUIC stream
/// priorities — scheduling fairness is the session mux's concern.
struct MobileHostDotSendStreamAdapter: CmxIrohSendStream {
    let stream: any DotStream

    func send(_ data: Data) async throws {
        try await stream.write(data)
    }

    func finish() async throws {
        await stream.closeWrite()
    }

    func reset(errorCode: UInt64) async {
        await stream.close()
    }

    func setPriority(_ priority: Int32) async throws {}
}

/// Server-events lane writer over dot: the host opens the `events` stream
/// lazily on first send and resets it on stall so the host service can
/// renegotiate, mirroring `MobileHostIrxEventWriter`.
actor MobileHostDotEventWriter: MobileHostIndependentEventWriting {
    private let session: any DotSecureSessionProtocol
    private let journal: DotJournal
    private var stream: (any DotStream)?

    init(session: any DotSecureSessionProtocol, journal: DotJournal) {
        self.session = session
        self.journal = journal
    }

    func probe(_ framedData: Data) async -> Bool {
        do {
            try await send(framedData)
            return true
        } catch {
            return false
        }
    }

    func send(_ framedData: Data) async throws {
        let stream = try await openedStream()
        try await stream.write(framedData)
    }

    func reset() async {
        if let stream {
            await stream.close()
        }
        stream = nil
        journal.record(component: "host-events", event: "writer-reset")
    }

    func close() async {
        if let stream {
            await stream.close()
        }
        stream = nil
    }

    private func openedStream() async throws -> any DotStream {
        if let stream { return stream }
        let opened = try await session.openStream(.events)
        stream = opened
        journal.record(component: "host-events", event: "writer-opened")
        return opened
    }
}
