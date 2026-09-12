import Foundation

/// In-process host: runs the REAL admission exchange (L2), the grant expiry
/// lifecycle (3.6), and an echo service against the substrate seam. Written
/// against `PeerConnection`, so the same host logic serves loopback today and
/// the iroh / tailnet substrates in P1; only the dial/accept plumbing differs.
public actor TransportHost {
    /// Supplies the account every admission and renewal must carry; returning
    /// nil fails closed as ``DenialCode/accountMismatch``.
    public typealias AccountIDProvider = @Sendable () async -> String?
    /// Durable hook for explicit grant revocations. The host awaits this
    /// callback before returning so a process restart cannot forget a revoke.
    public typealias GrantRevocationHandler = @Sendable (String) async -> Void

    /// Frame echo lane used by transport validation harnesses.
    public static let echoLaneName = "echo"
    /// The chat fan-out lane: frames from one admitted peer forward to every
    /// other admitted peer, the same shape as terminal streams fanning out.
    public static let chatLaneName = "chat"
    static let controlLaneName = "ctl"

    let verifier: GrantVerifier
    let accountIDProvider: AccountIDProvider?
    private let onGrantRevoked: GrantRevocationHandler?
    let frameTypePolicy = FrameTypePolicy()
    /// 3.6d: how long past expiry a session survives awaiting renewal.
    private let expiryGraceSeconds: Int64
    /// 3.6c: how long before expiry the warning frame is sent.
    private let expiryWarningSeconds: Int64
    var revokedGrantIDs: Set<String> = []
    var admissionOverride: DenialCode?
    var sessions: [SessionKey: ActiveSession] = [:]
    var sessionCounter = 0
    /// The most recent lifecycle tick, retained for diagnostics and explicit
    /// simulated-time callers. Fresh operations use `epochNow` instead of
    /// trusting this potentially stale snapshot.
    var currentTime: Int64 = 0
    /// Wall-clock source used for operations that can arrive between explicit
    /// lifecycle ticks (for example a relay push or grant renewal). Tests may
    /// inject a deterministic epoch source; the compatibility fallback below
    /// also keeps an explicitly simulated `serve(now:)` timeline stable.
    private let epochNow: @Sendable () -> Int64
    /// Clock seam for the bounded initial hello deadline. Tests inject an
    /// immediate cancellation-aware sleeper; production uses wall time.
    let handshakeSleep: @Sendable (Duration) async throws -> Void
    /// Admission reservations fence actor reentrancy while an older session's
    /// close is awaited. Only the reservation owner may install a session.
    var admissionReservations: [SessionKey: UInt64] = [:]
    var admissionReservationCounter: UInt64 = 0
    /// Admission, denial, closure, and renewal totals for this host lifetime.
    public internal(set) var counters = TransportCounters()

    /// Creates a host with explicit trust, revocation, and time dependencies.
    /// - Parameters:
    ///   - verifier: Offline verifier containing the pinned signing public key.
    ///   - expiryGraceSeconds: Renewal grace after expiry; defaults to one day.
    ///   - expiryWarningSeconds: Pre-expiry warning window; defaults to one hour.
    ///   - epochNow: Unix-time source; defaults to the system wall clock.
    ///   - accountIDProvider: Current account source; nil omits account binding for harnesses.
    ///   - initialRevokedGrantIDs: Durable denylist restored before accepting peers.
    ///   - onGrantRevoked: Awaited persistence hook; nil keeps revocations in memory only.
    ///   - handshakeSleep: Cancellable hello-deadline sleeper; defaults to a continuous clock.
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

    /// Denies future admission, awaits persistence, and closes sessions using this grant.
    /// - Parameter id: Grant revocation handle; never evicted to admit a newer handle.
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

    /// Number of registered sessions before the next closed-session reap.
    public var sessionCount: Int { sessions.count }

    /// Registered device identifiers in unspecified order; multiple app identities may repeat one.
    public var sessionDeviceIDs: [String] { sessions.keys.map(\.deviceID) }

    /// Number of admitted sessions whose chat service has finished registering.
    /// This is an observable readiness signal for chat/fan-out callers and
    /// tests; it avoids guessing with a fixed number of scheduler yields.
    public var chatEndpointCount: Int { chatEndpoints.count }

    /// Reads a fresh epoch while preserving deterministic simulated timelines.
    /// A test that supplies `serve(now:)` values far from the wall clock is
    /// treated as explicitly clocked until the next host instance is created.
    func verificationNow() -> Int64 {
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

    /// Reads the session currently registered for a device/app pair.
    /// - Parameter key: Supersession identity to look up.
    /// - Returns: A snapshot, or nil when no session is registered for this key.
    public func session(for key: SessionKey) -> ActiveSession? {
        sessions[key]
    }

    /// The admitted session bound to one live connection, if any. Host
    /// applications attach bridged services with this after `serve` admits.
    public func activeSession(for connection: any PeerConnection) -> ActiveSession? {
        sessions.values.first { $0.connection === connection }
    }

    /// Closes and removes the session owned by one exact connection. This is
    /// the canonical cleanup path for lifecycle owners that discover an
    /// admitted connection after their generation has gone stale: removal is
    /// identity-checked before the await so a newer session for the same
    /// device cannot be evicted, while the stale connection is always closed.
    /// - Returns: Whether a registered session was removed.
    @discardableResult
    public func closeSession(
        for connection: any PeerConnection, reason: CloseReason
    ) async -> Bool {
        guard let key = sessions.first(where: { $0.value.connection === connection })?.key else {
            await connection.closeAll(
                reason: ConnectionTermination(code: reason.code))
            return false
        }
        guard let session = sessions[key], session.connection === connection else {
            await connection.closeAll(
                reason: ConnectionTermination(code: reason.code))
            return false
        }
        sessions.removeValue(forKey: key)
        session.cancelServices()
        await connection.closeAll(
            reason: ConnectionTermination(code: reason.code))
        counters.closesByCode[reason.code, default: 0] += 1
        return true
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
                guard let current = sessions[key], current.connection === session.connection,
                    current.grant == session.grant
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
                    latest.grant == session.grant, !latest.warnedExpiring
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
    var pendingRelayCredentials: [SessionKey: (url: String, token: String)] = [:]

    /// Whether a stored credential is provably stale at `now`.
    static func credentialExpired(token: String, now: Int64) -> Bool {
        guard let expiry = IrohSubstrate().tokenExpiry(token) else { return false }
        return expiry <= now
    }

    /// Stores a nonexpired credential for replay and attempts immediate control-lane delivery.
    /// - Parameters:
    ///   - deviceID: Destination's durable device identifier.
    ///   - appIdentity: Destination's app identity.
    ///   - url: Relay URL to which the token is scoped.
    ///   - token: Secret credential; tokens with a known past expiry are refused.
    ///   - now: Optional Unix time; defaults to the host's current verification clock.
    /// - Returns: True only after sending to the still-current session; false may still cache it.
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
                    tokenExp=\(IrohSubstrate().tokenExpiry(token).map(String.init) ?? "unparsed", privacy: .public) \
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
                    tokenExp=\(IrohSubstrate().tokenExpiry(token).map(String.init) ?? "unparsed", privacy: .public)
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
                    tokenExp=\(IrohSubstrate().tokenExpiry(token).map(String.init) ?? "unparsed", privacy: .public)
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

    struct ChatEndpoint {
        let owner: ObjectIdentifier
        let lane: any TransportLane
    }

    var chatEndpoints: [SessionKey: ChatEndpoint] = [:]

}
