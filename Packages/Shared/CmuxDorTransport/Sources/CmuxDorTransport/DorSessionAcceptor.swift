// Mac-side acceptor: parks the standing host leg on the account's Durable
// Object, answers phone handshakes, verifies pair grants against the pinned
// trust keys, and emits admitted E2E sessions to the host runtime.
//
// One phone leg carries at most one live session: a repeated identical hs1
// (phone retrying a lost answer) gets the SAME hs2 + a fresh sealed admit; an
// hs1 with a new ephemeral supersedes the leg's previous session (the phone
// started over). Dead sessions reap via their own keepalive timeout.

import CryptoKit
import Foundation

public actor DorSessionAcceptor {
    private struct LegHandshake {
        let initiatorEphB64: String
        let hs2Payload: Data
        let session: DorSecureSession
    }

    private let configuration: DorSessionAcceptorConfiguration
    private let journal: DorJournal

    private var leg: DorLeg?
    private var continuation: AsyncStream<DorAcceptorEvent>.Continuation?
    private var pumpTask: Task<Void, Never>?
    private var handshakesByLeg: [UInt32: LegHandshake] = [:]
    private var stopped = false

    public init(configuration: DorSessionAcceptorConfiguration) {
        self.configuration = configuration
        self.journal = configuration.leg.journal
    }

    public func start() -> AsyncStream<DorAcceptorEvent> {
        precondition(pumpTask == nil, "DorSessionAcceptor.start called twice")
        let (stream, continuation) = AsyncStream<DorAcceptorEvent>.makeStream(
            bufferingPolicy: .unbounded)
        self.continuation = continuation
        let leg = DorLeg(configuration: configuration.leg)
        self.leg = leg
        pumpTask = Task { await self.pump(leg: leg) }
        return stream
    }

    public func stop() async {
        stopped = true
        pumpTask?.cancel()
        pumpTask = nil
        for (_, handshake) in handshakesByLeg {
            await handshake.session.close(reason: "acceptor-stopped")
        }
        handshakesByLeg = [:]
        await leg?.stop()
        leg = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Leg event pump (single consumer)

    private func pump(leg: DorLeg) async {
        let events = await leg.start()
        for await event in events {
            if stopped || Task.isCancelled { return }
            switch event {
            case let .frame(sourceLegID, payload):
                await handleFrame(sourceLegID: sourceLegID, payload: payload)
            case .reset(let reason):
                // Leg continuity is gone: every session over it is dead.
                await failAllSessions(reason: "leg-reset:\(reason)")
                continuation?.yield(.legEvent(event))
            case .closed:
                await failAllSessions(reason: "leg-closed")
                continuation?.yield(.legEvent(event))
                continuation?.finish()
                continuation = nil
                return
            case .peerOffline:
                // Phones blip and resume; their sessions outlive this. True
                // death reaps via the session keepalive timeout.
                continuation?.yield(.legEvent(event))
            case .up, .suspended, .resumed, .peerOnline:
                continuation?.yield(.legEvent(event))
            }
        }
    }

    private func failAllSessions(reason: String) async {
        let handshakes = handshakesByLeg
        handshakesByLeg = [:]
        for (_, handshake) in handshakes {
            await handshake.session.legFailed(reason: reason)
        }
    }

    private func handleFrame(sourceLegID: UInt32, payload: Data) async {
        switch payload.first {
        case DorBoxKind.handshake.rawValue:
            await handleHS1(sourceLegID: sourceLegID, json: Data(payload.dropFirst()))
        case DorBoxKind.sealed.rawValue:
            await handshakesByLeg[sourceLegID]?.session.handleInbound(payload)
        default:
            break
        }
    }

    // MARK: - Admission

    private func handleHS1(sourceLegID: UInt32, json: Data) async {
        guard json.count <= DorWire.maxHandshakeBytes else {
            await deny(sourceLegID: sourceLegID, deviceID: nil, reason: "malformed-hs1")
            return
        }
        guard let hs1 = try? JSONDecoder().decode(DorHandshake1.self, from: json),
              hs1.t == "hs1",
              let initiatorEph = Data(base64Encoded: hs1.eph), initiatorEph.count == 32,
              let initiatorID = Data(base64Encoded: hs1.id), initiatorID.count == 32,
              let signature = Data(base64Encoded: hs1.sig), signature.count == 64
        else {
            await deny(sourceLegID: sourceLegID, deviceID: nil, reason: "malformed-hs1")
            return
        }

        // Duplicate of the current handshake (the phone lost our answer):
        // replay the SAME hs2 and re-confirm inside the session.
        if let existing = handshakesByLeg[sourceLegID], existing.initiatorEphB64 == hs1.eph {
            await sendHandshake(existing.hs2Payload, to: sourceLegID)
            try? await existing.session.sendAdmit()
            return
        }

        // Possession proof for the identity key the grant pins.
        let hs1Message = DorTranscript.hs1Message(
            eph: initiatorEph, identity: initiatorID, grantJWS: hs1.grant)
        guard DorEd25519.verify(signature: signature, message: hs1Message, publicKey: initiatorID)
        else {
            await deny(sourceLegID: sourceLegID, deviceID: nil, reason: "bad-signature")
            return
        }

        // Grant verification against the pinned trust keys, tuple-bound to
        // the authenticated initiator and THIS acceptor identity.
        let claims: DorPairGrantClaims
        do {
            claims = try DorGrantVerifier.verifyPairGrant(
                hs1.grant,
                keys: configuration.admission.grantVerificationKeys,
                authenticatedInitiatorHex: initiatorID.lowercaseHex,
                acceptorHex: configuration.identity.publicKey.lowercaseHex
            )
        } catch {
            await deny(
                sourceLegID: sourceLegID, deviceID: nil,
                reason: "invalid-grant")
            return
        }
        let peer = DorAdmittedPeer(
            identityPublicKey: initiatorID,
            deviceID: claims.initiator.deviceID,
            platform: claims.initiator.platform,
            tag: claims.initiator.tag,
            bindingID: claims.initiator.bindingID,
            grantJTI: claims.grantID
        )
        do {
            try await configuration.judge(peer)
        } catch {
            await deny(
                sourceLegID: sourceLegID, deviceID: peer.deviceID,
                reason: "not-admitted")
            return
        }

        // A new ephemeral supersedes the leg's previous session.
        if let previous = handshakesByLeg.removeValue(forKey: sourceLegID) {
            await previous.session.close(reason: "superseded-by-handshake")
        }

        // hs2 + session keys.
        let responderEph = Curve25519.KeyAgreement.PrivateKey()
        let responderEphPublic = responderEph.publicKey.rawRepresentation
        let responderID = configuration.identity.publicKey
        let sessionID = UUID().uuidString.lowercased()
        let hs2Message = DorTranscript.hs2Message(
            responderEph: responderEphPublic,
            initiatorEph: initiatorEph,
            responderIdentity: responderID,
            session: sessionID
        )
        let hs2Signature: Data
        do {
            hs2Signature = try await configuration.identity.sign(hs2Message)
        } catch {
            await deny(sourceLegID: sourceLegID, deviceID: peer.deviceID, reason: "sign-failed")
            return
        }
        let hs2 = DorHandshake2(
            v: 1, t: "hs2",
            eph: responderEphPublic.base64EncodedString(),
            id: responderID.base64EncodedString(),
            sig: hs2Signature.base64EncodedString(),
            session: sessionID
        )
        guard let hs2Bytes = try? JSONEncoder().encode(hs2),
              let sharedSecret = try? responderEph.sharedSecretFromKeyAgreement(
                with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: initiatorEph)),
              let leg
        else { return }
        let keys = DorSessionKeys(
            sharedSecret: sharedSecret, hs1Bytes: json, hs2Bytes: hs2Bytes)
        let session = DorSecureSession(
            role: .responder,
            peer: peer,
            sessionID: sessionID,
            keys: keys,
            leg: leg,
            destination: sourceLegID,
            journal: journal
        )
        session.setOnEnded { [weak self] _ in
            Task { await self?.noteSessionEnded(legID: sourceLegID, session: session) }
        }
        var hs2Payload = Data([DorBoxKind.handshake.rawValue])
        hs2Payload.append(hs2Bytes)
        handshakesByLeg[sourceLegID] = LegHandshake(
            initiatorEphB64: hs1.eph, hs2Payload: hs2Payload, session: session)

        await sendHandshake(hs2Payload, to: sourceLegID)
        await session.activate()
        try? await session.sendAdmit()
        journal.record(
            component: "admission", event: "admitted",
            attributes: [
                "session": sessionID,
                "device": peer.deviceID,
                "peer": String(peer.identityHex.prefix(12)),
            ])
        continuation?.yield(.admitted(session))
    }

    private func noteSessionEnded(legID: UInt32, session: DorSecureSession) {
        if let current = handshakesByLeg[legID], current.session === session {
            handshakesByLeg.removeValue(forKey: legID)
        }
    }

    private func deny(sourceLegID: UInt32, deviceID: String?, reason: String) async {
        let safeReason = DorSafety.stableReason(reason, fallback: "admission-denied")
        journal.record(
            component: "admission", event: "denied",
            attributes: ["device": deviceID ?? "-", "reason": safeReason])
        let deny = DorHandshakeDeny(v: 1, t: "deny", reason: safeReason)
        if let bytes = try? JSONEncoder().encode(deny) {
            var payload = Data([DorBoxKind.handshake.rawValue])
            payload.append(bytes)
            await sendHandshake(payload, to: sourceLegID)
        }
        continuation?.yield(.denied(deviceID: deviceID, reason: safeReason))
    }

    private func sendHandshake(_ payload: Data, to legID: UInt32) async {
        guard let leg else { return }
        try? await leg.send(payload, to: legID)
    }
}
