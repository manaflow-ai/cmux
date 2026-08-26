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
    }

    /// The lane the echo service listens on; P0's stand-in for a terminal lane.
    public static let echoLaneName = "echo"
    /// The chat fan-out lane: frames from one admitted peer forward to every
    /// other admitted peer, the same shape as terminal streams fanning out.
    public static let chatLaneName = "chat"
    private static let controlLaneName = "ctl"

    private let verifier: GrantVerifier
    /// 3.6d: how long past expiry a session survives awaiting renewal.
    private let expiryGraceSeconds: Int64
    /// 3.6c: how long before expiry the warning frame is sent.
    private let expiryWarningSeconds: Int64
    private var revokedGrantIDs: Set<String> = []
    private var admissionOverride: DenialCode?
    private var sessions: [SessionKey: ActiveSession] = [:]
    private var sessionCounter = 0
    /// The host's notion of "now", injected by serve()/enforceExpiries() so
    /// every lifecycle behavior is deterministic in tests. The P1 runtime
    /// advances it from a real clock; no timers live in this layer.
    private var currentTime: Int64 = 0
    public private(set) var counters = TransportCounters()

    public init(
        verifier: GrantVerifier,
        expiryGraceSeconds: Int64 = 86_400,
        expiryWarningSeconds: Int64 = 3_600
    ) {
        self.verifier = verifier
        self.expiryGraceSeconds = expiryGraceSeconds
        self.expiryWarningSeconds = expiryWarningSeconds
    }

    public func revokeGrant(id: String) {
        if TransportDebugLog.enabled {
            TransportDebugLog.host.notice(
                "host grant revoked id=\(TransportDebugLog.prefix(id), privacy: .public)")
        }
        revokedGrantIDs.insert(id)
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
        guard let hello = await control.receive(), hello.type == FrameTypes.hello else {
            if TransportDebugLog.enabled {
                TransportDebugLog.host.error(
                    """
                    host hello parse failed conn=\(TransportDebugLog.id(connection), privacy: .public): \
                    no frame or wrong type
                    """)
            }
            await deny(.malformedHello, connection: connection)
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

        let decision = verifier.decide(
            grant: grant, presentedByKey: presentedKey, presentedByDeviceID: deviceID,
            presentedByApp: appIdentity, revokedGrantIDs: revokedGrantIDs, now: now)
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
            var supersededSessionID: String?
            if let old = sessions.removeValue(forKey: key) {
                supersededSessionID = old.id
                await old.connection.closeAll(
                    reason: ConnectionTermination(code: CloseReason.superseded.code))
                counters.closesByCode[CloseReason.superseded.code, default: 0] += 1
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
            Task { await self.runControlService(key: key, connection: connection) }
            Task { await self.runEchoService(connection: connection) }
            Task { await self.runChatService(key: key, connection: connection) }
        }
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
                await session.connection.closeAll(
                    reason: ConnectionTermination(code: CloseReason.grantExpired.code))
                counters.closesByCode[CloseReason.grantExpired.code, default: 0] += 1
            } else if now >= expiresAt - expiryWarningSeconds, !session.warnedExpiring {
                if TransportDebugLog.enabled {
                    TransportDebugLog.host.notice(
                        """
                        host grant expiry WARNING session=\(session.id, privacy: .public) \
                        device=\(TransportDebugLog.prefix(key.deviceID), privacy: .public) \
                        exp=\(expiresAt, privacy: .public) now=\(now, privacy: .public) \
                        warningSeconds=\(self.expiryWarningSeconds, privacy: .public)
                        """)
                }
                sessions[key]?.warnedExpiring = true
                let control = await session.connection.lane(Self.controlLaneName)
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
    private var pendingRelayCredentials: [SessionKey: (url: String, token: String)] = [:]

    public func pushRelayCredential(
        deviceID: String, appIdentity: String, url: String, token: String
    ) async -> Bool {
        _ = await reapClosedSessions()  // never claim delivery to a zombie
        let key = SessionKey(deviceID: deviceID, appIdentity: appIdentity)
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
            let decision = verifier.decide(
                grant: renewed, presentedByKey: session.deviceKey,
                presentedByDeviceID: key.deviceID, presentedByApp: key.appIdentity,
                revokedGrantIDs: revokedGrantIDs, now: currentTime)
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

    public static func connect(
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
        let sessionID = reply.payload["session"]?.stringValue ?? ""
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
