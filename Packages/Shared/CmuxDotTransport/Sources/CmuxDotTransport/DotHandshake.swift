// Handshake exchange helpers (pure, no I/O): build/verify hs1 and hs2 leg
// payloads and derive the session keys. See DotCrypto.swift for the
// primitives and transcript definitions.
//
// Key-derivation transcript convention: `hs1Bytes`/`hs2Bytes` are the exact
// JSON bytes as transmitted (the leg payload minus its 1-byte kind prefix),
// so both sides hash identical bytes without canonicalization.

import CryptoKit
import Foundation

enum DotHandshakeError: Error, Sendable {
    case malformed
    case unexpectedType
    case signatureInvalid
    case identityPinMismatch
    case denied(String)
}

/// Unencrypted denial the responder returns for a refused hs1, so the phone
/// fails fast instead of waiting out its admit deadline.
struct DotHandshakeDeny: Codable, Sendable {
    let v: Int
    let t: String
    let reason: String

    static func payload(reason: String) -> Data {
        var payload = Data([DotBoxKind.handshake.rawValue])
        let deny = DotHandshakeDeny(v: 1, t: "deny", reason: reason)
        payload.append((try? JSONEncoder().encode(deny)) ?? Data())
        return payload
    }
}

/// Initiator (phone) half of the exchange.
struct DotHandshakeInitiator: Sendable {
    let hs1Payload: Data
    private let hs1JSON: Data
    private let ephemeralKeyData: Data

    private init(hs1Payload: Data, hs1JSON: Data, ephemeralKeyData: Data) {
        self.hs1Payload = hs1Payload
        self.hs1JSON = hs1JSON
        self.ephemeralKeyData = ephemeralKeyData
    }

    static func make(
        identity: any DotIdentitySigning,
        grantJWS: String
    ) async throws -> DotHandshakeInitiator {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let ephPublic = ephemeral.publicKey.rawRepresentation
        let identityPublic = identity.publicKey
        let message = DotHandshakeTranscript.hs1Message(
            eph: ephPublic, identity: identityPublic, grantJWS: grantJWS)
        let signature = try await identity.sign(message)
        let hs1 = DotHandshake1(
            v: 1, t: "hs1",
            eph: ephPublic.base64EncodedString(),
            id: identityPublic.base64EncodedString(),
            sig: signature.base64EncodedString(),
            grant: grantJWS
        )
        let json = try JSONEncoder().encode(hs1)
        var payload = Data([DotBoxKind.handshake.rawValue])
        payload.append(json)
        return DotHandshakeInitiator(
            hs1Payload: payload,
            hs1JSON: json,
            ephemeralKeyData: ephemeral.rawRepresentation
        )
    }

    /// Verify the responder's hs2 against the pinned Mac identity and derive
    /// the session keys. `hs2Payload` is the raw leg payload (kind prefix
    /// included).
    func processHs2(
        _ hs2Payload: Data,
        expectedPeerPublicKey: Data?
    ) throws -> (keys: DotSessionKeys, sessionID: String, peerIdentity: Data) {
        guard hs2Payload.first == DotBoxKind.handshake.rawValue else {
            throw DotHandshakeError.malformed
        }
        let json = Data(hs2Payload.dropFirst())
        if let deny = try? JSONDecoder().decode(DotHandshakeDeny.self, from: json),
            deny.t == "deny"
        {
            throw DotHandshakeError.denied(deny.reason)
        }
        guard let hs2 = try? JSONDecoder().decode(DotHandshake2.self, from: json),
            hs2.t == "hs2", hs2.v == 1,
            let responderEph = Data(base64URLOrStandard: hs2.eph),
            responderEph.count == 32,
            let responderIdentity = Data(base64URLOrStandard: hs2.id),
            responderIdentity.count == 32,
            let signature = Data(base64URLOrStandard: hs2.sig),
            signature.count == 64,
            !hs2.session.isEmpty, hs2.session.utf8.count <= 128
        else {
            throw DotHandshakeError.malformed
        }
        if let expectedPeerPublicKey, responderIdentity != expectedPeerPublicKey {
            throw DotHandshakeError.identityPinMismatch
        }
        let ephemeral = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: ephemeralKeyData)
        let message = DotHandshakeTranscript.hs2Message(
            responderEph: responderEph,
            initiatorEph: ephemeral.publicKey.rawRepresentation,
            responderIdentity: responderIdentity
        )
        guard DotEd25519.verify(
            signature: signature, message: message, publicKey: responderIdentity)
        else {
            throw DotHandshakeError.signatureInvalid
        }
        let shared = try ephemeral.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: responderEph))
        let keys = DotSessionKeys(
            sharedSecret: shared, hs1Bytes: hs1JSON, hs2Bytes: json)
        return (keys, hs2.session, responderIdentity)
    }
}

/// Responder (Mac) half of the exchange.
enum DotHandshakeResponder {
    struct Outcome: Sendable {
        let hs2Payload: Data
        let keys: DotSessionKeys
        let sessionID: String
        let peer: DotAdmittedPeer
    }

    /// Verify an inbound hs1 (signature → grant → judge), then mint hs2 and
    /// the session keys. Throws `DotHandshakeError.denied` (with a coarse
    /// reason safe to transmit) on refusal.
    static func respond(
        hs1Payload: Data,
        identity: any DotIdentitySigning,
        admission: DotAdmissionMaterial,
        judge: @Sendable (DotAdmittedPeer) async throws -> Void,
        now: Date = Date()
    ) async throws -> Outcome {
        guard hs1Payload.first == DotBoxKind.handshake.rawValue else {
            throw DotHandshakeError.malformed
        }
        let json = Data(hs1Payload.dropFirst())
        guard let hs1 = try? JSONDecoder().decode(DotHandshake1.self, from: json),
            hs1.t == "hs1", hs1.v == 1,
            let initiatorEph = Data(base64URLOrStandard: hs1.eph),
            initiatorEph.count == 32,
            let initiatorIdentity = Data(base64URLOrStandard: hs1.id),
            initiatorIdentity.count == 32,
            let signature = Data(base64URLOrStandard: hs1.sig),
            signature.count == 64
        else {
            throw DotHandshakeError.malformed
        }
        let message = DotHandshakeTranscript.hs1Message(
            eph: initiatorEph, identity: initiatorIdentity, grantJWS: hs1.grant)
        guard DotEd25519.verify(
            signature: signature, message: message, publicKey: initiatorIdentity)
        else {
            throw DotHandshakeError.signatureInvalid
        }
        let initiatorHex = initiatorIdentity.map { String(format: "%02x", $0) }
            .joined()
        let acceptorHex = identity.publicKey.map { String(format: "%02x", $0) }
            .joined()
        let claims: DotPairGrantClaims
        do {
            claims = try DotGrantVerifier.verifyPairGrant(
                hs1.grant,
                keys: admission.grantVerificationKeys,
                authenticatedInitiatorHex: initiatorHex,
                acceptorHex: acceptorHex,
                now: now
            )
        } catch {
            throw DotHandshakeError.denied("grant_rejected")
        }
        let peer = DotAdmittedPeer(
            identityPublicKey: initiatorIdentity,
            deviceID: claims.initiator.deviceID,
            platform: claims.initiator.platform,
            tag: claims.initiator.tag,
            bindingID: claims.initiator.bindingID,
            grantJTI: claims.grantID
        )
        do {
            try await judge(peer)
        } catch {
            throw DotHandshakeError.denied("policy_rejected")
        }

        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let responderEph = ephemeral.publicKey.rawRepresentation
        let sessionID = UUID().uuidString.lowercased()
        let hs2Message = DotHandshakeTranscript.hs2Message(
            responderEph: responderEph,
            initiatorEph: initiatorEph,
            responderIdentity: identity.publicKey
        )
        let hs2Signature = try await identity.sign(hs2Message)
        let hs2 = DotHandshake2(
            v: 1, t: "hs2",
            eph: responderEph.base64EncodedString(),
            id: identity.publicKey.base64EncodedString(),
            sig: hs2Signature.base64EncodedString(),
            session: sessionID
        )
        let hs2JSON = try JSONEncoder().encode(hs2)
        var payload = Data([DotBoxKind.handshake.rawValue])
        payload.append(hs2JSON)
        let shared = try ephemeral.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: initiatorEph))
        let keys = DotSessionKeys(
            sharedSecret: shared, hs1Bytes: json, hs2Bytes: hs2JSON)
        return Outcome(
            hs2Payload: payload, keys: keys, sessionID: sessionID, peer: peer)
    }
}
