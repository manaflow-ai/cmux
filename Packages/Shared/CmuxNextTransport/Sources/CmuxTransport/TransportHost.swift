import Foundation

/// Observability is contractual (8.1, 8.2): admissions, denials by reason,
/// closes by reason, renewals. The lab screen renders these live in P1.
public struct TransportCounters: Sendable, Equatable {
    public var admissions = 0
    public var denialsByCode: [String: Int] = [:]
    public var closesByCode: [String: Int] = [:]
    public var grantRenewals = 0
    public var grantRenewalRejections = 0

    public init() {}
}

/// In-process host: runs the REAL admission exchange (L2), the grant expiry
/// lifecycle (3.6), and an echo service against the substrate seam. Written
/// against `PeerConnection`, so the same host logic serves loopback today and
/// the iroh / tailnet substrates in P1; only the dial/accept plumbing differs.
public actor TransportHost {
    private enum HelloReadOutcome: Sendable {
        case frame(Frame)
        case eof
        case timeout
    }
    /// Supplies the account currently authenticated on the host. When set,
    /// every admission and renewal must carry that same account ID; returning
    /// nil fails closed as ``DenialCode/accountMismatch``.
    public typealias AccountIDProvider = @Sendable () async -> String?
    /// Durable hook for explicit grant revocations. The host awaits this
    /// callback before returning so a process restart cannot forget a revoke.
    public typealias GrantRevocationHandler = @Sendable (String) async -> Void

    /// Supersession is keyed by (device ID, app identity), not by network key,
    /// so a reinstalled app with a freshly generated key still instantly
    /// replaces its own old session (contract 1.5, 4.5).
    public struct SessionKey: Hashable, Sendable {
        public let deviceID: String
        public let appIdentity: String
    }

    public struct ActiveSession: Sendable {
        public let id: String
        public let connection: any PeerConnection
        /// Kept for in-session renewal verification (3.6c): a renewal must be
        /// for the SAME key, device, and app the session was admitted with.
        public var deviceKey: Data
        public var grant: PairingGrant
        public var warnedExpiring = false
        /// The per-session service loops (control, echo, chat). Stored so
        /// every removal path can CANCEL them: on a half-open connection the
        /// lanes never EOF, and unstored loops outlive the session forever.
        var serviceTasks: [Task<Void, Never>] = []

        func cancelServices() {
            for task in serviceTasks { task.cancel() }
        }
    }

    /// The lane the echo service listens on; P0's stand-in for a terminal lane.
    public static let echoLaneName = "echo"
    /// The chat fan-out lane: frames from one admitted peer forward to every
    /// other admitted peer, the same shape as terminal streams fanning out.
    public static let chatLaneName = "chat"
    private static let controlLaneName = "ctl"

    private let verifier: GrantVerifier
    private let accountIDProvider: AccountIDProvider?
    private let onGrantRevoked: GrantRevocationHandler?
    private let frameTypePolicy = FrameTypePolicy()
    /// 3.6d: how long past expiry a session survives awaiting renewal.
    private let expiryGraceSeconds: Int64
    /// 3.6c: how long before expiry the warning frame is sent.
    private let expiryWarningSeconds: Int64
    private var revokedGrantIDs: Set<String> = []
    private var admissionOverride: DenialCode?
    private var sessions: [SessionKey: ActiveSession] = [:]
    private var sessionCounter = 0
    /// The most recent lifecycle tick, retained for diagnostics and explicit
    /// simulated-time callers. Fresh operations use `epochNow` instead of
    /// trusting this potentially stale snapshot.
    private var currentTime: Int64 = 0
    /// Wall-clock source used for operations that can arrive between explicit
    /// lifecycle ticks (for example a relay push or grant renewal). Tests may
    /// inject a deterministic epoch source; the compatibility fallback below
    /// also keeps an explicitly simulated `serve(now:)` timeline stable.
    private let epochNow: @Sendable () -> Int64
    /// Clock seam for the bounded initial hello deadline. Tests inject an
    /// immediate cancellation-aware sleeper; production uses wall time.
    private let handshakeSleep: @Sendable (Duration) async throws -> Void
    /// Admission reservations fence actor reentrancy while an older session's
    /// close is awaited. Only the reservation owner may install a session.
    private var admissionReservations: [SessionKey: UInt64] = [:]
    private var admissionReservationCounter: UInt64 = 0
    public private(set) var counters = TransportCounters()

    public init(
        verifier: GrantVerifier,
        expiryGraceSeconds: Int64 = 86_400,
        expiryWarningSeconds: Int64 = 3_600,
        epochNow: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970)
        },
        accountIDProvider: AccountIDProvider? = nil,
        initialRevokedGrantIDs: Set<String> = [],
        onGrantRevoked: GrantRevocationHandler? = nil,
        handshakeSleep: @escaping @Sendable (Duration) async throws -> Void = { delay in
            try await ContinuousClock().sleep(for: delay)
        }
    ) {
        self.verifier = verifier
        self.accountIDProvider = accountIDProvider
        self.onGrantRevoked = onGrantRevoked
        self.expiryGraceSeconds = expiryGraceSeconds
        self.expiryWarningSeconds = expiryWarningSeconds
        self.epochNow = epochNow
        self.handshakeSleep = handshakeSleep
        self.revokedGrantIDs = initialRevokedGrantIDs
    }

    public func revokeGrant(id: String) async {
        if TransportDebugLog.enabled {
            TransportDebugLog.host.notice(
                "host grant revoked id=\(TransportDebugLog.prefix(id), privacy: .public)")
        }
        revokedGrantIDs.insert(id)
        await onGrantRevoked?(id)
        // Revocation is authoritative for already-admitted sessions too:
        // close every matching connection immediately instead of waiting for
        // its next reconnect or expiry tick.
        let matches = sessions.filter { _, session in session.grant.grantID == id }
        for (key, session) in matches {
            guard let current = sessions[key], current.connection === session.connection else {
                continue
            }
            sessions.removeValue(forKey: key)
            current.cancelServices()
            await current.connection.closeAll(
                reason: ConnectionTermination(code: DenialCode.revoked.rawValue))
            counters.closesByCode[DenialCode.revoked.rawValue, default: 0] += 1
        }
    }

    /// Fault injection (harness spec 1.2): deny every admission with a fixed
    /// code until cleared.
    public func setAdmissionOverride(_ code: DenialCode?) {
        if TransportDebugLog.enabled {
            TransportDebugLog.host.notice(
                "host admission override set code=\(code?.rawValue ?? "cleared", privacy: .public)")
        }
        admissionOverride = code
    }

    /// Fault injection: kill one live session with an attributed reason, as
    /// if the host abruptly evicted it.
    public func killSession(deviceID: String, appIdentity: String) async -> Bool {
        let key = SessionKey(deviceID: deviceID, appIdentity: appIdentity)
        guard let session = sessions.removeValue(forKey: key) else { return false }
        session.cancelServices()
        if TransportDebugLog.enabled {
            TransportDebugLog.host.notice(
                """
                host killSession session=\(session.id, privacy: .public) \
                device=\(TransportDebugLog.prefix(deviceID), privacy: .public) \
                app=\(appIdentity, privacy: .public) \
                code=\(CloseReason.faultInjected.code, privacy: .public)
                """)
        }
        await session.connection.closeAll(
            reason: ConnectionTermination(code: CloseReason.faultInjected.code))
        counters.closesByCode[CloseReason.faultInjected.code, default: 0] += 1
        return true
    }

    public var sessionCount: Int { sessions.count }

    public var sessionDeviceIDs: [String] { sessions.keys.map(\.deviceID) }

    /// Number of admitted sessions whose chat service has finished registering.
    /// This is an observable readiness signal for chat/fan-out callers and
    /// tests; it avoids guessing with a fixed number of scheduler yields.
    public var chatEndpointCount: Int { chatEndpoints.count }

    /// Reads a fresh epoch while preserving deterministic simulated timelines.
    /// A test that supplies `serve(now:)` values far from the wall clock is
    /// treated as explicitly clocked until the next host instance is created.
    private func verificationNow() -> Int64 {
        epochNow()
    }

    /// Reconcile the table against the substrate's OWN liveness signal.
    /// Stream-EOF-driven reaping lags a silent peer death by up to QUIC's
    /// timeout (~90s observed); anything consulting the table for liveness
    /// (status, pushes, the rig's rotation gate) calls this first so the
    /// table cannot serve zombies.
    public func reapClosedSessions() async -> Int {
        var reaped = 0
        for (key, session) in sessions {
            guard await session.connection.isClosed else { continue }
            // Re-check ownership after the suspension: the same device may
            // have reconnected (supersession) while we awaited.
            guard let current = self.sessions[key], current.connection === session.connection
            else { continue }
            self.sessions.removeValue(forKey: key)
            current.cancelServices()
            counters.closesByCode["connection-lost", default: 0] += 1
            reaped += 1
            if TransportDebugLog.enabled {
                TransportDebugLog.host.notice(
                    """
                    host reaped zombie session=\(session.id, privacy: .public) \
                    device=\(TransportDebugLog.prefix(key.deviceID), privacy: .public) \
                    app=\(key.appIdentity, privacy: .public) \
                    conn=\(TransportDebugLog.id(session.connection), privacy: .public) \
                    code=connection-lost
                    """)
            }
        }
        if TransportDebugLog.enabled, reaped > 0 {
            TransportDebugLog.host.notice(
                """
                host reap complete reaped=\(reaped, privacy: .public) \
                liveSessions=\(self.sessions.count, privacy: .public)
                """)
        }
        return reaped
    }

    public func session(for key: SessionKey) -> ActiveSession? {
        sessions[key]
    }

    /// Serve one incoming connection: read ctl.hello, decide, admit or deny.
    /// Single-phase admission on the first control frame (contract 3.2).
    public func serve(connection: any PeerConnection, now: Int64) async {
        currentTime = now
        let serveStart = ContinuousClock.now
        if TransportDebugLog.enabled {
            TransportDebugLog.host.notice(
                """
                host serve begin conn=\(TransportDebugLog.id(connection), privacy: .public) \
                now=\(now, privacy: .public) \
                liveSessions=\(self.sessions.count, privacy: .public)
                """)
        }
        let control = await connection.lane(Self.controlLaneName)
        guard let hello = await receiveHello(
            from: control, connection: connection), hello.type == FrameTypes.hello else {
            if TransportDebugLog.enabled {
                TransportDebugLog.host.error(
                    """
                    host hello parse failed conn=\(TransportDebugLog.id(connection), privacy: .public): \
                    no frame or wrong type
                    """)
            }
            if await !connection.isClosed {
                await deny(.malformedHello, connection: connection)
            }
            return
        }
        if let override = admissionOverride {
            if TransportDebugLog.enabled {
                TransportDebugLog.host.notice(
                    """
                    host admission override firing conn=\(TransportDebugLog.id(connection), privacy: .public) \
                    code=\(override.rawValue, privacy: .public)
                    """)
            }
            await deny(
                override, connection: connection,
                deviceID: hello.payload["deviceId"]?.stringValue)
            return
        }
        guard hello.payload["protocol"]?.stringValue == CmuxPeerProtocol.identifier else {
            if TransportDebugLog.enabled {
                TransportDebugLog.host.error(
                    """
                    host protocol mismatch conn=\(TransportDebugLog.id(connection), privacy: .public) \
                    presented=\(hello.payload["protocol"]?.stringValue ?? "nil", privacy: .public) \
                    expected=\(CmuxPeerProtocol.identifier, privacy: .public)
                    """)
            }
            await deny(
                .protocolMismatch, connection: connection,
                deviceID: hello.payload["deviceId"]?.stringValue)
            return
        }
        guard
            let helloKey = hello.payload["key"]?.dataValue,
            let deviceID = hello.payload["deviceId"]?.stringValue,
            let appIdentity = hello.payload["app"]?.stringValue,
            let grant = PairingGrant(payloadValue: hello.payload["grant"])
        else {
            if TransportDebugLog.enabled {
                TransportDebugLog.host.error(
                    """
                    host hello missing fields conn=\(TransportDebugLog.id(connection), privacy: .public) \
                    key=\(hello.payload["key"]?.dataValue != nil, privacy: .public) \
                    deviceId=\(hello.payload["deviceId"]?.stringValue != nil, privacy: .public) \
                    app=\(hello.payload["app"]?.stringValue != nil, privacy: .public) \
                    grant=\(PairingGrant(payloadValue: hello.payload["grant"]) != nil, privacy: .public)
                    """)
            }
            await deny(
                .malformedHello, connection: connection,
                deviceID: hello.payload["deviceId"]?.stringValue)
            return
        }

        // Contract 3.5: when the substrate authenticated the remote key, that
        // key is the truth. A hello that self-reports a different key is a
        // protocol violation, and the grant is judged against the
        // authenticated key, never the claimed one.
        let substrateKey = await connection.authenticatedRemoteKey
        if let substrateKey, substrateKey != helloKey {
            if TransportDebugLog.enabled {
                TransportDebugLog.host.error(
                    """
                    host key mismatch conn=\(TransportDebugLog.id(connection), privacy: .public) \
                    device=\(TransportDebugLog.prefix(deviceID), privacy: .public) \
                    substrateKey=\(TransportDebugLog.hex8(substrateKey), privacy: .public) \
                    helloKey=\(TransportDebugLog.hex8(helloKey), privacy: .public)
                    """)
            }
            await deny(.keyMismatch, connection: connection, deviceID: deviceID)
            return
        }
        let presentedKey = substrateKey ?? helloKey

        let expectedAccountID = await accountIDProvider?()
        let decision: AdmissionDecision
        if accountIDProvider != nil && expectedAccountID == nil {
            // A configured account provider that cannot produce an authenticated
            // identity is a signed-out host, never an unrestricted host.
            decision = .deny(.accountMismatch)
        } else {
            decision = verifier.decide(
                grant: grant, presentedByKey: presentedKey, presentedByDeviceID: deviceID,
                presentedByApp: appIdentity, revokedGrantIDs: revokedGrantIDs, now: now,
                expectedAccountID: expectedAccountID)
        }
        switch decision {
        case .deny(let code):
            if TransportDebugLog.enabled {
                TransportDebugLog.host.error(
                    """
                    host grant verification denied conn=\(TransportDebugLog.id(connection), privacy: .public) \
                    code=\(code.rawValue, privacy: .public) \
                    device=\(TransportDebugLog.prefix(deviceID), privacy: .public) \
                    app=\(appIdentity, privacy: .public) \
                    grantID=\(TransportDebugLog.prefix(grant.grantID), privacy: .public) \
                    grantExp=\(grant.expiresAt.map(String.init) ?? "none", privacy: .public)
                    """)
            }
            await deny(code, connection: connection, deviceID: deviceID)

        case .admit:
            // Supersession (contract 4.5): a new connection from the same
            // (device, app) identity IMMEDIATELY replaces the old session.
            // A dead process's session must never block re-admission; the
            // field logs showed an ~85s lockout doing exactly that.
            let key = SessionKey(deviceID: deviceID, appIdentity: appIdentity)
            admissionReservationCounter &+= 1
            let reservation = admissionReservationCounter
            admissionReservations[key] = reservation
            var supersededSessionID: String?
            if let old = sessions.removeValue(forKey: key) {
                supersededSessionID = old.id
                old.cancelServices()
                await old.connection.closeAll(
                    reason: ConnectionTermination(code: CloseReason.superseded.code))
                counters.closesByCode[CloseReason.superseded.code, default: 0] += 1
            }
            // The close above suspends this actor. A newer admission for the
            // same identity may have claimed the reservation while we waited;
            // never let this stale connection become an untracked session.
            guard admissionReservations[key] == reservation else {
                await connection.closeAll(
                    reason: ConnectionTermination(code: CloseReason.superseded.code))
                return
            }
            sessionCounter += 1
            let session = ActiveSession(
                id: "s\(sessionCounter)", connection: connection, deviceKey: presentedKey,
                grant: grant)
            sessions[key] = session
            counters.admissions += 1
            if TransportDebugLog.enabled {
                if let supersededSessionID {
                    TransportDebugLog.host.notice(
                        """
                        host supersession device=\(TransportDebugLog.prefix(deviceID), privacy: .public) \
                        app=\(appIdentity, privacy: .public) \
                        oldSession=\(supersededSessionID, privacy: .public) -> \
                        newSession=\(session.id, privacy: .public)
                        """)
                }
                TransportDebugLog.host.notice(
                    """
                    host ADMITTED session=\(session.id, privacy: .public) \
                    conn=\(TransportDebugLog.id(connection), privacy: .public) \
                    device=\(TransportDebugLog.prefix(deviceID), privacy: .public) \
                    app=\(appIdentity, privacy: .public) \
                    key=\(TransportDebugLog.hex8(presentedKey), privacy: .public) \
                    grantID=\(TransportDebugLog.prefix(grant.grantID), privacy: .public) \
                    grantExp=\(grant.expiresAt.map(String.init) ?? "none", privacy: .public) \
                    admissions=\(self.counters.admissions, privacy: .public) \
                    elapsedMs=\(TransportDebugLog.ms(since: serveStart), privacy: .public)
                    """)
            }
            try? await control.send(Frame.admit(sessionID: session.id))
            guard admissionReservations[key] == reservation,
                sessions[key]?.connection === connection
            else {
                await connection.closeAll(
                    reason: ConnectionTermination(code: CloseReason.superseded.code))
                return
            }
            if let credential = pendingRelayCredentials[key],
                Self.credentialExpired(token: credential.token, now: now)
            {
                // Provably stale: replaying it would hand the client a dead
                // relay route. Drop it; the next rotation push refills.
                pendingRelayCredentials.removeValue(forKey: key)
                if TransportDebugLog.enabled {
                    TransportDebugLog.host.notice(
                        """
                        host dropped expired pending relay credential \
                        session=\(session.id, privacy: .public) \
                        device=\(TransportDebugLog.prefix(deviceID), privacy: .public) \
                        url=\(credential.url, privacy: .public) \
                        tokenExp=\(IrohSubstrate.tokenExpiry(credential.token).map(String.init) ?? "unparsed", privacy: .public) \
                        now=\(now, privacy: .public)
                        """)
                }
            }
            if let credential = pendingRelayCredentials[key] {
                if TransportDebugLog.enabled {
                    TransportDebugLog.host.notice(
                        """
                        host replaying pending relay credential on admission \
                        session=\(session.id, privacy: .public) \
                        device=\(TransportDebugLog.prefix(deviceID), privacy: .public) \
                        url=\(credential.url, privacy: .public)
                        """)
                }
                try? await control.send(
                    Frame.relayCredential(url: credential.url, token: credential.token))
            }
            let serviceTasks = [
                Task { await self.runControlService(key: key, connection: connection) },
                Task { await self.runEchoService(connection: connection) },
                Task { await self.runChatService(key: key, connection: connection) },
            ]
            if let current = sessions[key], current.connection === connection {
                sessions[key]?.serviceTasks = serviceTasks
            } else {
                // Superseded during the admit send: these loops belong to a
                // session that is already gone. Kill them, never leak them.
                for task in serviceTasks { task.cancel() }
            }
            if admissionReservations[key] == reservation {
                admissionReservations.removeValue(forKey: key)
            }
        }
    }

    /// Reads the first control frame with a bounded, cancellation-aware
    /// deadline. Closing the connection on timeout wakes substrates whose FFI
    /// receive future does not observe task cancellation on its own.
    private func receiveHello(
        from control: any TransportLane,
        connection: any PeerConnection
    ) async -> Frame? {
        let outcome = await withTaskGroup(of: HelloReadOutcome.self) { group in
            group.addTask {
                guard let frame = await control.receive() else { return .eof }
                return .frame(frame)
            }
            let sleep = handshakeSleep
            group.addTask {
                do {
                    try await sleep(.seconds(10))
                } catch {
                    return .eof
                }
                return .timeout
            }
            let result = await group.next() ?? .eof
            group.cancelAll()
            if case .timeout = result {
                await connection.closeAll(
                    reason: ConnectionTermination(code: DenialCode.malformedHello.rawValue))
            }
            await group.waitForAll()
            return result
        }
        if case .frame(let frame) = outcome { return frame }
        return nil
    }

    /// The admitted session bound to one live connection, if any. Host
    /// applications attach bridged services with this after `serve` admits.
    public func activeSession(for connection: any PeerConnection) -> ActiveSession? {
        sessions.values.first { $0.connection === connection }
    }

    /// The expiry lifecycle (contract 3.6), driven by an injected clock:
    /// warn inside the warning window, close ONCE after expiry + grace.
    /// Expiry alone never closes anything (3.6b).
    public func enforceExpiries(now: Int64) async {
        currentTime = now
        for (key, session) in sessions {
            guard let expiresAt = session.grant.expiresAt else { continue }
            if now >= expiresAt + expiryGraceSeconds {
                // The snapshot may be stale after the close await below; only
                // remove the entry if this exact connection still owns the key.
                guard let current = sessions[key], current.connection === session.connection
                else { continue }
                if TransportDebugLog.enabled {
                    TransportDebugLog.host.notice(
                        """
                        host grant expiry close session=\(session.id, privacy: .public) \
                        device=\(TransportDebugLog.prefix(key.deviceID), privacy: .public) \
                        code=\(CloseReason.grantExpired.code, privacy: .public) \
                        exp=\(expiresAt, privacy: .public) now=\(now, privacy: .public) \
                        graceSeconds=\(self.expiryGraceSeconds, privacy: .public)
                        """)
                }
                sessions.removeValue(forKey: key)
                current.cancelServices()
                await current.connection.closeAll(
                    reason: ConnectionTermination(code: CloseReason.grantExpired.code))
                counters.closesByCode[CloseReason.grantExpired.code, default: 0] += 1
            } else if now >= expiresAt - expiryWarningSeconds, !session.warnedExpiring {
                guard let current = sessions[key], current.connection === session.connection,
                    !current.warnedExpiring
                else { continue }
                if TransportDebugLog.enabled {
                    TransportDebugLog.host.notice(
                        """
                        host grant expiry WARNING session=\(session.id, privacy: .public) \
                        device=\(TransportDebugLog.prefix(key.deviceID), privacy: .public) \
                        exp=\(expiresAt, privacy: .public) now=\(now, privacy: .public) \
                        warningSeconds=\(self.expiryWarningSeconds, privacy: .public)
                        """)
                }
                let control = await current.connection.lane(Self.controlLaneName)
                // A supersession may have happened while lane() suspended.
                guard let latest = sessions[key], latest.connection === current.connection,
                    !latest.warnedExpiring
                else { continue }
                sessions[key]?.warnedExpiring = true
                try? await control.send(Frame.grantExpiring(expiresAt: expiresAt))
            }
        }
    }

    /// Push a fresh relay credential to one live session over its ctl lane:
    /// contract 9.7's renewal in miniature (credentials ride the standing
    /// channel; the client rotates in place, no reconnect). Returns false
    /// when no such session is live.
    /// The freshest credential per device, delivered on EVERY admission:
    /// mid-session pushes race connection flaps and suspensions (field: no
    /// push ever landed), but admission is the one moment the ctl lane is
    /// provably alive, and reconnects happen constantly anyway.
    /// Entries whose token expiry (JWT `exp`, 300s fleet lifetime) has passed
    /// are dropped on insert and before replay: replaying a stale token makes
    /// the relay route silently dead (the 08-21 field bite), which is worse
    /// than replaying nothing. Unparseable tokens are kept (staleness cannot
    /// be proven; harness tokens are opaque).
    private var pendingRelayCredentials: [SessionKey: (url: String, token: String)] = [:]

    /// Whether a stored credential is provably stale at `now`.
    private static func credentialExpired(token: String, now: Int64) -> Bool {
        guard let expiry = IrohSubstrate.tokenExpiry(token) else { return false }
        return expiry <= now
    }

    public func pushRelayCredential(
        deviceID: String, appIdentity: String, url: String, token: String,
        now: Int64? = nil
    ) async -> Bool {
        _ = await reapClosedSessions()  // never claim delivery to a zombie
        // Callers that own a simulated/lifecycle clock may supply the exact
        // observation instant. Otherwise read the fresh injected wall clock;
        // never reuse a stale `serve(now:)` value after a long idle gap.
        let now = now ?? verificationNow()
        currentTime = now
        let key = SessionKey(deviceID: deviceID, appIdentity: appIdentity)
        // Insert is also the prune point: without it, keys for devices that
        // never reconnect accumulate expired tokens forever.
        pendingRelayCredentials = pendingRelayCredentials.filter {
            !Self.credentialExpired(token: $0.value.token, now: now)
        }
        if Self.credentialExpired(token: token, now: now) {
            if TransportDebugLog.enabled {
                TransportDebugLog.host.error(
                    """
                    host relay credential REFUSED (already expired) \
                    device=\(TransportDebugLog.prefix(deviceID), privacy: .public) \
                    url=\(url, privacy: .public) \
                    tokenExp=\(IrohSubstrate.tokenExpiry(token).map(String.init) ?? "unparsed", privacy: .public) \
                    now=\(now, privacy: .public)
                    """)
            }
            return false
        }
        pendingRelayCredentials[key] = (url: url, token: token)
        guard let session = sessions[key] else {
            if TransportDebugLog.enabled {
                TransportDebugLog.host.notice(
                    """
                    host relay credential stored (no live session) \
                    device=\(TransportDebugLog.prefix(deviceID), privacy: .public) \
                    app=\(appIdentity, privacy: .public) \
                    url=\(url, privacy: .public) \
                    tokenExp=\(IrohSubstrate.tokenExpiry(token).map(String.init) ?? "unparsed", privacy: .public)
                    """)
            }
            return false
        }
        let control = await session.connection.lane(Self.controlLaneName)
        // A reconnect can supersede this session while lane() suspends. Do
        // not deliver a fresh credential to a stale connection.
        guard sessions[key]?.connection === session.connection else {
            return false
        }
        do {
            try await control.send(Frame.relayCredential(url: url, token: token))
            if TransportDebugLog.enabled {
                TransportDebugLog.host.notice(
                    """
                    host relay credential PUSHED session=\(session.id, privacy: .public) \
                    device=\(TransportDebugLog.prefix(deviceID), privacy: .public) \
                    url=\(url, privacy: .public) \
                    tokenExp=\(IrohSubstrate.tokenExpiry(token).map(String.init) ?? "unparsed", privacy: .public)
                    """)
            }
            return true
        } catch {
            if TransportDebugLog.enabled {
                TransportDebugLog.host.error(
                    """
                    host relay credential push FAILED session=\(session.id, privacy: .public) \
                    device=\(TransportDebugLog.prefix(deviceID), privacy: .public) \
                    url=\(url, privacy: .public) \
                    error=\(String(describing: error), privacy: .public)
                    """)
            }
            return false
        }
    }

    /// One channel, no timing dependence (contract 3.3 v7): the code rides in
    /// the connection termination itself, which the substrate delivers as
    /// part of closing. There is no deny frame to race against the close.
    private func deny(
        _ code: DenialCode, connection: any PeerConnection, deviceID: String? = nil
    ) async {
        counters.denialsByCode[code.rawValue, default: 0] += 1
        if TransportDebugLog.enabled {
            TransportDebugLog.host.error(
                """
                host DENIED conn=\(TransportDebugLog.id(connection), privacy: .public) \
                code=\(code.rawValue, privacy: .public) \
                device=\(TransportDebugLog.prefix(deviceID), privacy: .public) \
                denialsForCode=\(self.counters.denialsByCode[code.rawValue] ?? 0, privacy: .public)
                """)
        }
        await connection.closeAll(reason: ConnectionTermination(code: code.rawValue))
    }

    /// Post-admission control-lane listener: handles in-session grant renewal
    /// (3.6c). Ends when the connection dies, which is also where the session
    /// table learns about natural connection loss: without reaping here the
    /// table lies (8.2), `status` reports a dead phone as present, and
    /// anything gating on liveness (the rig's rotation gate) deadlocks.
    private func runControlService(key: SessionKey, connection: any PeerConnection) async {
        defer {
            if let session = sessions[key], session.connection === connection {
                sessions.removeValue(forKey: key)
                // Take the echo/chat siblings down with the session; on a
                // half-open connection their lanes never EOF on their own.
                // (Cancelling this task itself is a harmless no-op: it is
                // already returning.)
                session.cancelServices()
                counters.closesByCode["connection-lost", default: 0] += 1
                if TransportDebugLog.enabled {
                    TransportDebugLog.host.notice(
                        """
                        host control service ended session=\(session.id, privacy: .public) \
                        device=\(TransportDebugLog.prefix(key.deviceID), privacy: .public) \
                        conn=\(TransportDebugLog.id(connection), privacy: .public) \
                        code=connection-lost \
                        liveSessions=\(self.sessions.count, privacy: .public)
                        """)
                }
            } else if TransportDebugLog.enabled {
                TransportDebugLog.host.notice(
                    """
                    host control service ended for superseded conn \
                    device=\(TransportDebugLog.prefix(key.deviceID), privacy: .public) \
                    conn=\(TransportDebugLog.id(connection), privacy: .public)
                    """)
            }
        }
        let control = await connection.lane(Self.controlLaneName)
        for await frame in control.frames {
            switch frameTypePolicy.classify(frame.type) {
            case .known:
                break
            case .ignorableUnknown:
                // Optional extensions are explicitly forward-compatible.
                continue
            case .fatalUnknown:
                if TransportDebugLog.enabled {
                    TransportDebugLog.host.error(
                        """
                        host ctl unknown mandatory frame; closing \
                        type=\(frame.type, privacy: .public) \
                        device=\(TransportDebugLog.prefix(key.deviceID), privacy: .public) \
                        conn=\(TransportDebugLog.id(connection), privacy: .public)
                        """)
                }
                await connection.closeAll(
                    reason: ConnectionTermination(code: DenialCode.protocolMismatch.rawValue))
                return
            }
            guard frame.type == FrameTypes.grantUpdate else {
                if TransportDebugLog.enabled {
                    TransportDebugLog.host.notice(
                        """
                        host ctl frame ignored type=\(frame.type, privacy: .public) \
                        device=\(TransportDebugLog.prefix(key.deviceID), privacy: .public) \
                        conn=\(TransportDebugLog.id(connection), privacy: .public)
                        """)
                }
                continue
            }
            // Ignore frames from a superseded session's connection.
            guard let session = sessions[key], session.connection === connection else {
                if TransportDebugLog.enabled {
                    TransportDebugLog.host.notice(
                        """
                        host grant renewal from superseded conn ignored \
                        device=\(TransportDebugLog.prefix(key.deviceID), privacy: .public) \
                        conn=\(TransportDebugLog.id(connection), privacy: .public)
                        """)
                }
                return
            }
            guard let renewed = PairingGrant(payloadValue: frame.payload["grant"]) else {
                counters.grantRenewalRejections += 1
                if TransportDebugLog.enabled {
                    TransportDebugLog.host.error(
                        """
                        host grant renewal MALFORMED session=\(session.id, privacy: .public) \
                        device=\(TransportDebugLog.prefix(key.deviceID), privacy: .public) \
                        rejections=\(self.counters.grantRenewalRejections, privacy: .public)
                        """)
                }
                try? await control.send(Frame.grantAck(accepted: false, code: .malformedHello))
                continue
            }
            let expectedAccountID = await accountIDProvider?()
            guard sessions[key]?.connection === connection else {
                return
            }
            let decision: AdmissionDecision
            if accountIDProvider != nil && expectedAccountID == nil {
                decision = .deny(.accountMismatch)
            } else {
                decision = verifier.decide(
                    grant: renewed, presentedByKey: session.deviceKey,
                    presentedByDeviceID: key.deviceID, presentedByApp: key.appIdentity,
                    revokedGrantIDs: revokedGrantIDs, now: verificationNow(),
                    expectedAccountID: expectedAccountID)
            }
            switch decision {
            case .admit:
                sessions[key]?.grant = renewed
                sessions[key]?.warnedExpiring = false
                counters.grantRenewals += 1
                if TransportDebugLog.enabled {
                    TransportDebugLog.host.notice(
                        """
                        host grant renewal ACCEPTED session=\(session.id, privacy: .public) \
                        device=\(TransportDebugLog.prefix(key.deviceID), privacy: .public) \
                        grantID=\(TransportDebugLog.prefix(renewed.grantID), privacy: .public) \
                        newExp=\(renewed.expiresAt.map(String.init) ?? "none", privacy: .public) \
                        renewals=\(self.counters.grantRenewals, privacy: .public)
                        """)
                }
                try? await control.send(Frame.grantAck(accepted: true))
            case .deny(let code):
                // The session is NOT closed: the old grant still governs
                // until its grace window lapses (3.6d).
                counters.grantRenewalRejections += 1
                if TransportDebugLog.enabled {
                    TransportDebugLog.host.error(
                        """
                        host grant renewal REJECTED session=\(session.id, privacy: .public) \
                        device=\(TransportDebugLog.prefix(key.deviceID), privacy: .public) \
                        code=\(code.rawValue, privacy: .public) \
                        grantID=\(TransportDebugLog.prefix(renewed.grantID), privacy: .public) \
                        rejections=\(self.counters.grantRenewalRejections, privacy: .public) \
                        (session stays open under old grant)
                        """)
                }
                try? await control.send(Frame.grantAck(accepted: false, code: code))
            }
        }
    }

    private struct ChatEndpoint {
        let owner: ObjectIdentifier
        let lane: any TransportLane
    }

    private var chatEndpoints: [SessionKey: ChatEndpoint] = [:]

    /// Chat fan-out: every chat frame from one peer forwards to every OTHER
    /// registered peer. Demo-grade backpressure policy: a peer that stops
    /// reading its chat lane stalls forwarding from THIS source (clients
    /// always read theirs); production fan-out gets the sync layer's
    /// cursor/coalescing treatment, out of transport scope by contract 5.4.
    private func runChatService(key: SessionKey, connection: any PeerConnection) async {
        let lane = await connection.lane(Self.chatLaneName)
        guard let session = sessions[key], session.connection === connection else { return }
        chatEndpoints[key] = ChatEndpoint(owner: ObjectIdentifier(connection), lane: lane)
        if TransportDebugLog.enabled {
            TransportDebugLog.host.notice(
                """
                host chat service registered session=\(session.id, privacy: .public) \
                device=\(TransportDebugLog.prefix(key.deviceID), privacy: .public) \
                endpoints=\(self.chatEndpoints.count, privacy: .public)
                """)
        }
        for await frame in lane.frames {
            switch frameTypePolicy.classify(frame.type) {
            case .known:
                break
            case .ignorableUnknown:
                continue
            case .fatalUnknown:
                await connection.closeAll(
                    reason: ConnectionTermination(code: DenialCode.protocolMismatch.rawValue))
                return
            }
            guard frame.type == FrameTypes.chatMessage || frame.type == FrameTypes.chatTyping
            else { continue }
            for (otherKey, endpoint) in chatEndpoints where otherKey != key {
                try? await endpoint.lane.send(frame)
            }
        }
        // Unregister only if this connection still owns the slot (a
        // superseding session may have re-registered the same key).
        if chatEndpoints[key]?.owner == ObjectIdentifier(connection) {
            chatEndpoints.removeValue(forKey: key)
        }
        if TransportDebugLog.enabled {
            TransportDebugLog.host.notice(
                """
                host chat service ended device=\(TransportDebugLog.prefix(key.deviceID), privacy: .public) \
                conn=\(TransportDebugLog.id(connection), privacy: .public) \
                endpoints=\(self.chatEndpoints.count, privacy: .public)
                """)
        }
    }

    private func runEchoService(connection: any PeerConnection) async {
        let echo = await connection.lane(Self.echoLaneName)
        for await frame in echo.frames {
            switch frameTypePolicy.classify(frame.type) {
            case .known:
                break
            case .ignorableUnknown:
                continue
            case .fatalUnknown:
                await connection.closeAll(
                    reason: ConnectionTermination(code: DenialCode.protocolMismatch.rawValue))
                return
            }
            guard frame.type == FrameTypes.dataChunk else { continue }
            do {
                try await echo.send(frame)
            } catch {
                if TransportDebugLog.enabled {
                    TransportDebugLog.host.error(
                        """
                        host echo service send FAILED \
                        conn=\(TransportDebugLog.id(connection), privacy: .public) \
                        error=\(String(describing: error), privacy: .public)
                        """)
                }
                return
            }
        }
        if TransportDebugLog.enabled {
            TransportDebugLog.host.notice(
                """
                host echo service ended conn=\(TransportDebugLog.id(connection), privacy: .public)
                """)
        }
    }
}

/// Client-side connect helper: sends hello, awaits the single-phase verdict.
public struct TransportClient: Sendable {
    public enum ConnectOutcome: Sendable, Equatable {
        case admitted(sessionID: String)
        case denied(DenialCode)
    }

    /// Performs the admission exchange with a cancellation escape hatch. A
    /// cancelled FFI lane read is explicitly woken by closing the connection;
    /// this keeps caller deadlines effective even when the underlying future
    /// does not observe Swift task cancellation on its own.
    public static func connect(
        connection: any PeerConnection, identity: PeerIdentity, grant: PairingGrant
    ) async throws -> ConnectOutcome {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await connectUncancelled(
                connection: connection, identity: identity, grant: grant)
        }, onCancel: {
            Task {
                await connection.closeAll(
                    reason: ConnectionTermination(code: "admission-cancelled"))
            }
        })
    }

    private static func connectUncancelled(
        connection: any PeerConnection, identity: PeerIdentity, grant: PairingGrant
    ) async throws -> ConnectOutcome {
        let connectStart = ContinuousClock.now
        let control = await connection.lane("ctl")
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                client hello send conn=\(TransportDebugLog.id(connection), privacy: .public) \
                device=\(TransportDebugLog.prefix(identity.deviceID), privacy: .public) \
                app=\(identity.appIdentity, privacy: .public) \
                grantID=\(TransportDebugLog.prefix(grant.grantID), privacy: .public)
                """)
        }
        try await control.send(Frame.hello(identity: identity, grant: grant))
        guard let reply = await control.receive() else {
            // No admit frame: a denial. The reason arrives in the connection
            // termination itself, delivered by the substrate without any
            // timing dependence (contract 3.3 v7).
            if let termination = await connection.termination(),
                let code = DenialCode(rawValue: termination.code)
            {
                if TransportDebugLog.enabled {
                    TransportDebugLog.core.error(
                        """
                        client connect DENIED conn=\(TransportDebugLog.id(connection), privacy: .public) \
                        device=\(TransportDebugLog.prefix(identity.deviceID), privacy: .public) \
                        code=\(code.rawValue, privacy: .public) \
                        elapsedMs=\(TransportDebugLog.ms(since: connectStart), privacy: .public)
                        """)
                }
                return .denied(code)
            }
            if TransportDebugLog.enabled {
                TransportDebugLog.core.error(
                    """
                    client connect FAILED conn=\(TransportDebugLog.id(connection), privacy: .public) \
                    device=\(TransportDebugLog.prefix(identity.deviceID), privacy: .public) \
                    cause=connection-closed-before-reply (no parsable termination) \
                    elapsedMs=\(TransportDebugLog.ms(since: connectStart), privacy: .public)
                    """)
            }
            throw TransportError.connectionClosedBeforeReply
        }
        guard reply.type == FrameTypes.admit else {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.error(
                    """
                    client connect FAILED conn=\(TransportDebugLog.id(connection), privacy: .public) \
                    device=\(TransportDebugLog.prefix(identity.deviceID), privacy: .public) \
                    cause=unexpected-frame type=\(reply.type, privacy: .public) \
                    elapsedMs=\(TransportDebugLog.ms(since: connectStart), privacy: .public)
                    """)
            }
            throw TransportError.unexpectedFrame(reply.type)
        }
        guard let sessionID = reply.payload["session"]?.stringValue,
            !sessionID.isEmpty
        else {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.error(
                    "client connect FAILED conn=\(TransportDebugLog.id(connection), privacy: .public) cause=empty-admit-session")
            }
            throw TransportError.unexpectedFrame("ctl.admit.empty-session")
        }
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                client connect ADMITTED conn=\(TransportDebugLog.id(connection), privacy: .public) \
                device=\(TransportDebugLog.prefix(identity.deviceID), privacy: .public) \
                session=\(TransportDebugLog.prefix(sessionID), privacy: .public) \
                elapsedMs=\(TransportDebugLog.ms(since: connectStart), privacy: .public)
                """)
        }
        return .admitted(sessionID: sessionID)
    }
}
