// Phone-side single reconnect owner for one Mac peer (IrxPeerEngine
// lineage). Leg blips resolve below this layer (transparent resume keeps the
// sealed counters intact); this engine only re-handshakes when the SESSION
// dies: host process restart (fresh keys), leg reset (continuity lost),
// admission denial, or a deliberate replacement close from above.
public import Foundation

public actor DotPeerEngine {
    /// hs1 answered by neither hs2 nor deny within this long ⇒ resend with a
    /// fresh ephemeral (the relay buffers uploads across host blips, so a
    /// slow host answers the FIRST hs1; this is for lost-to-fresh-host ones).
    private static let handshakeRetryInterval: TimeInterval = 10
    /// Bound on `readySession()` waiting for an admitted session.
    private static let readyDeadline: TimeInterval = 20

    private let configuration: DotPeerEngineConfiguration
    private let journal: DotJournal
    private let clock = ContinuousClock()

    private var leg: DotLeg?
    private var legLoop: Task<Void, Never>?
    private var legUp = false
    private var shutdownFlag = false

    private var state: DotPeerState = .idle
    private var stateContinuation: AsyncStream<DotPeerState>.Continuation?

    private var handshake: DotHandshakeInitiator?
    private var handshakeTimer: Task<Void, Never>?
    private var handshakeAttempt = 0
    private var currentSession: DotMuxSession?
    private var admitWait: Task<Void, Never>?
    private var dialStartedAt: ContinuousClock.Instant?

    private var readyWaiters:
        [(id: UUID, continuation: CheckedContinuation<any DotSecureSessionProtocol, any Error>)] = []

    public init(configuration: DotPeerEngineConfiguration) {
        self.configuration = configuration
        self.journal = configuration.leg.journal
    }

    /// Current state plus a stream of transitions (single consumer).
    public func states() -> AsyncStream<DotPeerState> {
        let (stream, continuation) = AsyncStream<DotPeerState>.makeStream()
        stateContinuation = continuation
        continuation.yield(state)
        return stream
    }

    /// Dial now (idempotent while connecting/ready).
    public func connect() async {
        guard !shutdownFlag else { return }
        startLegIfNeeded()
        if await liveSession() != nil { return }
        if case .connecting = state {} else {
            transition(.connecting)
            dialStartedAt = clock.now
        }
        if legUp, handshake == nil, currentSession == nil {
            await beginHandshake(trigger: "connect")
        }
    }

    /// Returns the ready session, dialing if needed, or throws after the
    /// bounded admission deadline.
    public func readySession() async throws -> any DotSecureSessionProtocol {
        if let session = await liveSession() { return session }
        await connect()
        if let session = await liveSession() { return session }
        let waiterID = UUID()
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.readyDeadline))
            guard !Task.isCancelled else { return }
            await self?.expireReadyWaiter(id: waiterID)
        }
        defer { deadline.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            readyWaiters.append((waiterID, continuation))
        }
    }

    public func shutdown() async {
        guard !shutdownFlag else { return }
        shutdownFlag = true
        handshakeTimer?.cancel()
        handshakeTimer = nil
        admitWait?.cancel()
        admitWait = nil
        legLoop?.cancel()
        legLoop = nil
        if let currentSession {
            await currentSession.fail(reason: "engine-shutdown")
        }
        currentSession = nil
        if let leg {
            await leg.stop()
        }
        leg = nil
        failWaiters(DotEngineError.shutdown)
        transition(.closed(reason: "shutdown"))
        stateContinuation?.finish()
        stateContinuation = nil
    }

    // MARK: - Leg lifecycle

    private func startLegIfNeeded() {
        guard leg == nil, !shutdownFlag else { return }
        let leg = DotLeg(configuration: configuration.leg)
        self.leg = leg
        dialStartedAt = clock.now
        legLoop = Task { [weak self] in
            let events = await leg.start()
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                await self.handleLegEvent(event)
            }
        }
    }

    private func handleLegEvent(_ event: DotLegEvent) async {
        guard !shutdownFlag else { return }
        switch event {
        case .up:
            legUp = true
            if currentSession == nil {
                await beginHandshake(trigger: "leg-up")
            }
        case .peerOnline:
            // The Mac (re)appeared. If we are between sessions, a fresh hs1
            // reaches it immediately instead of waiting out the retry timer.
            if legUp, currentSession == nil {
                await beginHandshake(trigger: "peer-online")
            }
        case .peerOffline(_, let reason):
            // The host leg dropped; it resumes invisibly for live sessions
            // (buffered by the relay). Nothing to do here.
            journal.record(
                component: "engine", event: "peer-offline",
                attributes: ["reason": reason ?? "-"]
            )
        case .suspended, .resumed:
            // Leg-internal continuity; sessions ride through it.
            break
        case .reset(let reason):
            // Leg continuity lost: sealed counters can no longer line up.
            legUp = false
            if let currentSession {
                await currentSession.fail(reason: "leg-reset: \(reason)")
            }
        case .frame(_, let payload):
            await handleFrame(payload)
        case .closed(let reason):
            legUp = false
            if let currentSession {
                await currentSession.fail(reason: "leg-closed: \(reason)")
            }
            currentSession = nil
            failWaiters(DotEngineError.legClosed(reason))
            transition(.closed(reason: reason))
        }
    }

    // MARK: - Handshake

    private func beginHandshake(trigger: String) async {
        guard !shutdownFlag, legUp, currentSession == nil else { return }
        guard let grantJWS = configuration.admission.grantJWS else {
            journal.record(
                component: "admission", event: "denied",
                attributes: ["reason": "no-grant"]
            )
            failWaiters(DotEngineError.denied("no-grant"))
            return
        }
        if dialStartedAt == nil {
            dialStartedAt = clock.now
        }
        do {
            let handshake = try await DotHandshakeInitiator.make(
                identity: configuration.identity, grantJWS: grantJWS)
            self.handshake = handshake
            guard let leg else { return }
            try await leg.send(handshake.hs1Payload, to: 0)
            journal.record(
                component: "engine", event: "hs1-sent",
                attributes: [
                    "trigger": trigger,
                    "attempt": String(handshakeAttempt),
                ]
            )
            scheduleHandshakeRetry()
        } catch {
            journal.record(
                component: "engine", event: "dial-failed",
                attributes: ["reason": String(describing: error)]
            )
            self.handshake = nil
            scheduleHandshakeRetry()
        }
    }

    private func scheduleHandshakeRetry() {
        handshakeTimer?.cancel()
        let attempt = handshakeAttempt
        handshakeAttempt += 1
        // Fixed interval with mild growth, capped: the relay buffers hs1
        // toward an absent host, so retries only cover fresh-host ring wipes.
        let delay = min(
            Self.handshakeRetryInterval + Double(attempt) * 5, 30)
        handshakeTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.handshakeRetryFired()
        }
    }

    private func handshakeRetryFired() async {
        guard !shutdownFlag, currentSession == nil else { return }
        handshake = nil
        await beginHandshake(trigger: "retry")
    }

    private func handleFrame(_ payload: Data) async {
        switch payload.first {
        case DotBoxKind.handshake.rawValue:
            await handleHandshakeFrame(payload)
        case DotBoxKind.sealed.rawValue:
            if let currentSession {
                await currentSession.handleInboundSealed(payload)
            }
        default:
            journal.record(component: "engine", event: "unknown-frame-kind")
        }
    }

    private func handleHandshakeFrame(_ payload: Data) async {
        guard let handshake else {
            // hs2 for a consumed/abandoned attempt (e.g. duplicate); drop.
            return
        }
        do {
            let outcome = try handshake.processHs2(
                payload,
                expectedPeerPublicKey: configuration.admission.expectedPeerPublicKey
            )
            self.handshake = nil
            handshakeTimer?.cancel()
            handshakeTimer = nil
            let macDeviceID = configuration.leg.macDeviceID
            let peer = DotAdmittedPeer(
                identityPublicKey: outcome.peerIdentity,
                deviceID: macDeviceID,
                platform: "mac",
                tag: nil,
                bindingID: nil,
                grantJTI: nil
            )
            guard let leg else { return }
            let session = DotMuxSession(
                role: .initiator,
                keys: outcome.keys,
                peer: peer,
                sessionID: outcome.sessionID,
                journal: journal,
                transmit: { data in
                    try await leg.send(data, to: 0)
                },
                onEnd: { [weak self] reason in
                    let sessionID = outcome.sessionID
                    Task {
                        await self?.sessionEnded(sessionID: sessionID, reason: reason)
                    }
                }
            )
            currentSession = session
            await session.begin()
            // Ready only after the sealed admit proves key agreement.
            admitWait?.cancel()
            admitWait = Task { [weak self] in
                do {
                    try await withDeadline(seconds: 15) {
                        try await session.waitAdmitted()
                    }
                    await self?.sessionAdmitted(session)
                } catch {
                    await session.fail(reason: "admit-timeout")
                }
            }
        } catch DotHandshakeError.denied(let reason) {
            self.handshake = nil
            journal.record(
                component: "admission", event: "denied",
                attributes: ["reason": reason]
            )
            failWaiters(DotEngineError.denied(reason))
            scheduleHandshakeRetry()
        } catch {
            // Malformed or mis-signed hs2: keep the attempt; the retry timer
            // re-handshakes if nothing valid arrives.
            journal.record(
                component: "engine", event: "hs2-rejected",
                attributes: ["reason": String(describing: error)]
            )
        }
    }

    private func sessionAdmitted(_ session: DotMuxSession) {
        guard !shutdownFlag, currentSession === session else { return }
        handshakeAttempt = 0
        let elapsedMS: Int64
        if let dialStartedAt {
            elapsedMS = dialStartedAt.duration(to: clock.now).milliseconds
        } else {
            elapsedMS = -1
        }
        dialStartedAt = nil
        journal.record(
            component: "admission", event: "admitted",
            attributes: [
                "session": session.sessionID,
                "elapsed_ms": String(elapsedMS),
            ]
        )
        transition(.ready(session))
        let waiters = readyWaiters
        readyWaiters = []
        for waiter in waiters {
            waiter.continuation.resume(returning: session)
        }
    }

    private func sessionEnded(sessionID: String, reason: String) async {
        guard let currentSession, currentSession.sessionID == sessionID else {
            return
        }
        self.currentSession = nil
        guard !shutdownFlag else { return }
        journal.record(
            component: "engine", event: "session-ended",
            attributes: ["session": sessionID, "reason": reason]
        )
        transition(.connecting)
        dialStartedAt = clock.now
        // THE reconnect owner: re-handshake immediately (leg.send buffers if
        // the leg is mid-recovery, so this is safe in every leg state).
        journal.record(
            component: "engine", event: "auto-redial",
            attributes: ["reason": reason]
        )
        if legUp {
            await beginHandshake(trigger: "session-ended")
        }
    }

    // MARK: - Helpers

    private func liveSession() async -> DotMuxSession? {
        guard let currentSession else { return nil }
        if await currentSession.isEnded {
            return nil
        }
        guard await currentSession.isAdmitted else { return nil }
        return currentSession
    }

    private func expireReadyWaiter(id: UUID) {
        guard let index = readyWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = readyWaiters.remove(at: index)
        journal.record(component: "admission", event: "timeout")
        waiter.continuation.resume(throwing: DotEngineError.admissionTimeout)
    }

    private func failWaiters(_ error: any Error) {
        let waiters = readyWaiters
        readyWaiters = []
        for waiter in waiters {
            waiter.continuation.resume(throwing: error)
        }
    }

    private func transition(_ newState: DotPeerState) {
        state = newState
        stateContinuation?.yield(newState)
    }
}

public enum DotEngineError: Error, Sendable {
    case shutdown
    case admissionTimeout
    case denied(String)
    case legClosed(String)
}

/// Run `operation` with a hard deadline; cancellation-based, no polling.
func withDeadline<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw DotEngineError.admissionTimeout
        }
        guard let result = try await group.next() else {
            throw DotEngineError.admissionTimeout
        }
        group.cancelAll()
        return result
    }
}
