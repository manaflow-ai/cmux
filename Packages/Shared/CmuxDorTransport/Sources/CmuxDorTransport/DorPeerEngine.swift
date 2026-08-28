// THE single reconnect owner for one Mac peer (phone side).
//
// Leg blips resolve below this layer (transparent resume). This engine
// redials only when the E2E session itself dies: host process restart
// (keepalive timeout — a new process cannot decrypt the old session), leg
// reset (provable loss), terminal leg close, or an explicit shutdown. Every
// redial builds a FRESH leg: one leg carries exactly one session lineage, so
// sequence floors and replay rings can never straddle two sessions.

import CryptoKit
import Foundation

public actor DorPeerEngine {
    private enum DialState {
        case awaitingUp
        case handshaking(eph: Curve25519.KeyAgreement.PrivateKey, hs1Bytes: Data, sentAt: ContinuousClock.Instant)
        case awaitingAdmit(session: DorSecureSession, since: ContinuousClock.Instant)
        case ready(session: DorSecureSession)
    }

    private enum PumpOutcome {
        case redial(String)
        case terminal(String)
        case shutdown
    }

    private let configuration: DorPeerEngineConfiguration
    private let journal: DorJournal

    private var state: DorPeerState = .idle
    private var stateContinuation: AsyncStream<DorPeerState>.Continuation?
    private var runTask: Task<Void, Never>?
    private var currentLeg: DorLeg?
    private var dial: DialState = .awaitingUp
    private var sessionEndReason: String?
    private var shutdownRequested = false
    private var readyWaiters: [CheckedContinuation<any DorSecureSessionProtocol, any Error>] = []
    private var episodeStart = ContinuousClock.now

    /// Bounded wait for `readySession`.
    private static let readyDeadline: Duration = .seconds(20)
    /// Resend hs1 / restart admission when stalled this long.
    private static let handshakeStall: Duration = .seconds(10)

    public init(configuration: DorPeerEngineConfiguration) {
        self.configuration = configuration
        self.journal = configuration.leg.journal
    }

    /// Current state transitions (single consumer).
    public func states() -> AsyncStream<DorPeerState> {
        let (stream, continuation) = AsyncStream<DorPeerState>.makeStream(
            bufferingPolicy: .unbounded)
        stateContinuation = continuation
        continuation.yield(state)
        return stream
    }

    /// Dial now (idempotent while connecting/ready).
    public func connect() async {
        guard !shutdownRequested, runTask == nil else { return }
        runTask = Task { await self.run() }
    }

    /// The ready session, dialing if needed; throws after a bounded deadline.
    public func readySession() async throws -> any DorSecureSessionProtocol {
        if case let .ready(session) = state { return session }
        if case let .closed(reason) = state { throw DorEngineError.closed(reason) }
        await connect()
        let waited = Task {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<any DorSecureSessionProtocol, any Error>) in
                readyWaiters.append(continuation)
            }
        }
        let timer = Task {
            try? await Task.sleep(for: Self.readyDeadline)
            await self.expireReadyWaiters()
        }
        defer { timer.cancel() }
        return try await waited.value
    }

    public func shutdown() async {
        shutdownRequested = true
        if case let .ready(session) = dialSession() {
            await session.close(reason: "shutdown")
        }
        await currentLeg?.stop()
        currentLeg = nil
        runTask?.cancel()
        setState(.closed(reason: "shutdown"))
        failWaiters(DorEngineError.closed("shutdown"))
    }

    // MARK: - Run loop

    private func run() async {
        var backoff: Duration = .milliseconds(500)
        while !shutdownRequested {
            episodeStart = ContinuousClock.now
            setState(.connecting)
            dial = .awaitingUp
            sessionEndReason = nil
            let leg = DorLeg(configuration: configuration.leg)
            currentLeg = leg
            let events = await leg.start()
            let stallTicker = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    await self.handshakeStallCheck()
                }
            }
            let outcome = await pump(events: events)
            stallTicker.cancel()
            await teardownEpisode(leg: leg)
            switch outcome {
            case .shutdown:
                setState(.closed(reason: "shutdown"))
                failWaiters(DorEngineError.closed("shutdown"))
                return
            case .terminal(let reason):
                journal.record(
                    component: "engine", event: "dial-failed",
                    attributes: ["reason": reason])
                setState(.closed(reason: reason))
                failWaiters(DorEngineError.closed(reason))
                return
            case .redial(let reason):
                journal.record(
                    component: "engine", event: "auto-redial",
                    attributes: ["reason": reason])
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, .seconds(10))
            }
        }
    }

    private func teardownEpisode(leg: DorLeg) async {
        if case let .awaitingAdmit(session, _) = dial {
            await session.close(reason: "episode-over")
        }
        if case let .ready(session) = dial {
            await session.legFailed(reason: sessionEndReason ?? "episode-over")
        }
        dial = .awaitingUp
        await leg.stop()
        if currentLeg === leg { currentLeg = nil }
    }

    /// Single consumer of the leg's event stream for one episode.
    private func pump(events: AsyncStream<DorLegEvent>) async -> PumpOutcome {
        for await event in events {
            if shutdownRequested { return .shutdown }
            switch event {
            case .up:
                await sendHS1()
            case .peerOnline:
                // The Mac (re)appeared. A fresh host process clears buffered
                // frames, so any in-flight handshake may be gone: restart it
                // unless the session is already established.
                switch dial {
                case .awaitingUp, .handshaking:
                    await sendHS1()
                case .awaitingAdmit, .ready:
                    break
                }
            case .peerOffline, .suspended, .resumed:
                continue
            case .reset(let reason):
                return outcomeForSessionDeath("leg-reset:\(reason)")
            case .closed(let reason):
                if let sessionEndReason {
                    return outcomeForSessionDeath(sessionEndReason)
                }
                // Terminal close codes end the engine; everything else retries.
                if reason == "superseded" || reason == "unauthorized" || reason == "capacity" {
                    return .terminal("leg-closed:\(reason)")
                }
                return .redial("leg-closed:\(reason)")
            case let .frame(_, payload):
                await handleFrame(payload)
                if let sessionEndReason {
                    return outcomeForSessionDeath(sessionEndReason)
                }
            }
        }
        if shutdownRequested { return .shutdown }
        if let sessionEndReason {
            return outcomeForSessionDeath(sessionEndReason)
        }
        return .redial("leg-stream-ended")
    }

    private func outcomeForSessionDeath(_ reason: String) -> PumpOutcome {
        if case .ready = dial {
            journal.record(
                component: "engine", event: "session-ended",
                attributes: ["reason": reason])
        }
        return .redial(reason)
    }

    // MARK: - Handshake

    private func sendHS1() async {
        guard let leg = currentLeg, let grant = configuration.admission.grantJWS else {
            if configuration.admission.grantJWS == nil {
                journal.record(
                    component: "admission", event: "denied",
                    attributes: ["reason": "no-grant"])
                sessionEndReason = "no-grant"
            }
            return
        }
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let ephPublic = eph.publicKey.rawRepresentation
        let identityPublic = configuration.identity.publicKey
        let message = DorTranscript.hs1Message(
            eph: ephPublic, identity: identityPublic, grantJWS: grant)
        let signature: Data
        do {
            signature = try await configuration.identity.sign(message)
        } catch {
            journal.record(
                component: "engine", event: "hs1-sign-failed",
                attributes: ["reason": "identity-sign-failed"])
            return
        }
        let hs1 = DorHandshake1(
            v: 1, t: "hs1",
            eph: ephPublic.base64EncodedString(),
            id: identityPublic.base64EncodedString(),
            sig: signature.base64EncodedString(),
            grant: grant
        )
        guard let hs1Bytes = try? JSONEncoder().encode(hs1) else { return }
        var payload = Data([DorBoxKind.handshake.rawValue])
        payload.append(hs1Bytes)
        dial = .handshaking(eph: eph, hs1Bytes: hs1Bytes, sentAt: .now)
        try? await leg.send(payload, to: 0)
    }

    private func handleFrame(_ payload: Data) async {
        switch payload.first {
        case DorBoxKind.handshake.rawValue:
            await handleHandshakePayload(payload.dropFirst())
        case DorBoxKind.sealed.rawValue:
            switch dial {
            case let .awaitingAdmit(session, _):
                await session.handleInbound(payload)
            case let .ready(session):
                await session.handleInbound(payload)
            case .awaitingUp, .handshaking:
                break // stale ciphertext from a previous lineage
            }
        default:
            break
        }
    }

    private func handleHandshakePayload(_ json: Data) async {
        guard json.count <= DorWire.maxHandshakeBytes else { return }
        if let deny = try? JSONDecoder().decode(DorHandshakeDeny.self, from: Data(json)),
           deny.t == "deny"
        {
            journal.record(
                component: "admission", event: "denied",
                attributes: [
                    "reason": DorSafety.stableReason(
                        deny.reason, fallback: "admission-denied")
                ])
            return
        }
        guard case let .handshaking(eph, hs1Bytes, _) = dial,
              let hs2 = try? JSONDecoder().decode(DorHandshake2.self, from: Data(json)),
              hs2.t == "hs2",
              let responderEph = Data(base64Encoded: hs2.eph), responderEph.count == 32,
              let responderID = Data(base64Encoded: hs2.id), responderID.count == 32,
              let signature = Data(base64Encoded: hs2.sig), signature.count == 64
        else { return }

        // The handshake must terminate at the EXACT identity the pair grant
        // pins; anything else is not our Mac.
        guard responderID == configuration.admission.expectedPeerPublicKey else {
            journal.record(
                component: "admission", event: "denied",
                attributes: ["reason": "responder-identity-mismatch"])
            return
        }
        let message = DorTranscript.hs2Message(
            responderEph: responderEph,
            initiatorEph: eph.publicKey.rawRepresentation,
            responderIdentity: responderID,
            session: hs2.session
        )
        guard DorEd25519.verify(signature: signature, message: message, publicKey: responderID)
        else {
            // A stale hs2 for an older ephemeral fails here by design; keep
            // waiting for the answer to the current attempt.
            return
        }
        let keys: DorSessionKeys
        do {
            let shared = try eph.sharedSecretFromKeyAgreement(
                with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: responderEph))
            keys = DorSessionKeys(sharedSecret: shared, hs1Bytes: hs1Bytes, hs2Bytes: Data(json))
        } catch {
            return
        }
        guard let leg = currentLeg else { return }
        let grantClaims = configuration.admission.grantJWS.flatMap(
            DorGrantVerifier.decodeClaimsForRouting)
        let session = DorSecureSession(
            role: .initiator,
            peer: DorAdmittedPeer(
                identityPublicKey: responderID,
                deviceID: configuration.leg.macDeviceID,
                platform: grantClaims?.acceptor.platform ?? "mac",
                tag: grantClaims?.acceptor.tag,
                bindingID: grantClaims?.acceptor.bindingID,
                grantJTI: grantClaims?.grantID
            ),
            sessionID: hs2.session,
            keys: keys,
            leg: leg,
            destination: 0,
            journal: journal
        )
        session.setOnEnded { [weak self] reason in
            Task { await self?.noteSessionEnded(reason: reason) }
        }
        dial = .awaitingAdmit(session: session, since: .now)
        await session.activate()
        Task { [weak self] in
            let admitted = await session.waitAdmitted(timeout: DorPeerEngine.handshakeStall)
            await self?.admitOutcome(session: session, admitted: admitted)
        }
    }

    private func admitOutcome(session: DorSecureSession, admitted: Bool) async {
        guard case let .awaitingAdmit(pending, _) = dial, pending === session else { return }
        guard admitted else {
            await session.close(reason: "admit-timeout")
            await sendHS1()
            return
        }
        dial = .ready(session: session)
        let elapsed = episodeStart.duration(to: .now)
        let elapsedMS = Int(elapsed.components.seconds) * 1000
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        journal.record(
            component: "admission", event: "admitted",
            attributes: [
                "elapsed_ms": String(elapsedMS),
                "session": session.sessionID,
                "peer": String(session.peer.identityHex.prefix(12)),
            ])
        setState(.ready(session))
        let waiters = readyWaiters
        readyWaiters = []
        for waiter in waiters {
            waiter.resume(returning: session)
        }
    }

    private func noteSessionEnded(reason: String) async {
        sessionEndReason = reason
        // Finish the episode: stopping the leg ends the pump's event stream.
        await currentLeg?.stop()
    }

    private func handshakeStallCheck() async {
        switch dial {
        case let .handshaking(_, _, sentAt) where ContinuousClock.now - sentAt > Self.handshakeStall:
            await sendHS1()
        case let .awaitingAdmit(session, since) where ContinuousClock.now - since > Self.handshakeStall * 2:
            await session.close(reason: "admit-stall")
            await sendHS1()
        default:
            break
        }
    }

    // MARK: - Helpers

    private func dialSession() -> DialState { dial }

    private func setState(_ new: DorPeerState) {
        state = new
        stateContinuation?.yield(new)
    }

    private func failWaiters(_ error: any Error) {
        let waiters = readyWaiters
        readyWaiters = []
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }

    private func expireReadyWaiters() {
        guard !readyWaiters.isEmpty else { return }
        journal.record(component: "admission", event: "timeout", attributes: [:])
        failWaiters(DorEngineError.admissionTimeout)
    }
}

public enum DorEngineError: Error, Sendable {
    case admissionTimeout
    case closed(String)
}
