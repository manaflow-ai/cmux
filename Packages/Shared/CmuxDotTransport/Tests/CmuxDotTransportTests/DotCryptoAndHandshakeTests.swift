import CryptoKit
import Foundation
import Testing

@testable import CmuxDotTransport

/// Test-only identity: an in-memory Ed25519 key.
struct TestIdentity: DotIdentitySigning {
    let key = Curve25519.Signing.PrivateKey()

    var publicKey: Data { key.publicKey.rawRepresentation }
    var hex: String { publicKey.map { String(format: "%02x", $0) }.joined() }

    func sign(_ message: Data) async throws -> Data {
        try key.signature(for: message)
    }
}

/// Mints broker-shaped pair grants signed with a test Ed25519 key.
enum TestGrantMint {
    static func grant(
        signingKey: Curve25519.Signing.PrivateKey,
        initiatorHex: String,
        acceptorHex: String,
        phoneDeviceID: String = "11111111-1111-1111-1111-111111111111",
        macDeviceID: String = "22222222-2222-2222-2222-222222222222",
        issuedAt: Int64 = Int64(Date().timeIntervalSince1970) - 10,
        lifetime: Int64 = 3600
    ) throws -> String {
        let header = base64URL(try JSONSerialization.data(withJSONObject: [
            "alg": "EdDSA", "typ": "cmux-pair-grant+jwt", "kid": "test-key",
        ]))
        let payload = base64URL(try JSONSerialization.data(withJSONObject: [
            "jti": "33333333-3333-3333-3333-333333333333",
            "iat": issuedAt,
            "nbf": issuedAt,
            "exp": issuedAt + lifetime,
            "alpn": "cmux/mobile/1",
            "scope": "cmux.mobile.attach",
            "initiator": [
                "bindingId": "44444444-4444-4444-4444-444444444444",
                "deviceId": phoneDeviceID,
                "tag": "dotx",
                "platform": "ios",
                "endpointId": initiatorHex,
                "identityGeneration": 1,
            ],
            "acceptor": [
                "bindingId": "55555555-5555-5555-5555-555555555555",
                "deviceId": macDeviceID,
                "tag": "dotx",
                "platform": "mac",
                "endpointId": acceptorHex,
                "identityGeneration": 1,
            ],
        ]))
        let signingInput = Data("\(header).\(payload)".utf8)
        let signature = try signingKey.signature(for: signingInput)
        return "\(header).\(payload).\(base64URL(signature))"
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

@Suite("sealed-box crypto")
struct DotCryptoTests {
    @Test func sealOpenRoundtripAndCounterEnforcement() throws {
        let key = SymmetricKey(size: .bits256)
        var sealer = DotSealer(key: key)
        var opener = DotOpener(key: key)

        let first = try sealer.seal(Data("one".utf8))
        let second = try sealer.seal(Data("two".utf8))
        #expect(first.first == DotBoxKind.sealed.rawValue)
        #expect(try opener.open(first) == Data("one".utf8))
        #expect(try opener.open(second) == Data("two".utf8))

        // Replay of an already-opened box is rejected by counter.
        #expect(throws: DotCryptoError.self) {
            var replayOpener = opener
            _ = try replayOpener.open(second)
        }
    }

    @Test func reorderRejected() throws {
        let key = SymmetricKey(size: .bits256)
        var sealer = DotSealer(key: key)
        var opener = DotOpener(key: key)
        let first = try sealer.seal(Data("one".utf8))
        let second = try sealer.seal(Data("two".utf8))
        #expect(try opener.open(second) == Data("two".utf8))
        #expect(throws: DotCryptoError.self) {
            _ = try opener.open(first)
        }
    }

    @Test func tamperedBoxRejected() throws {
        let key = SymmetricKey(size: .bits256)
        var sealer = DotSealer(key: key)
        var opener = DotOpener(key: key)
        var box = try sealer.seal(Data("payload".utf8))
        box[box.count - 1] ^= 0xFF
        #expect(throws: DotCryptoError.self) {
            _ = try opener.open(box)
        }
    }
}

@Suite("grant verification")
struct DotGrantVerifierTests {
    @Test func mintedGrantVerifies() throws {
        let broker = Curve25519.Signing.PrivateKey()
        let phone = TestIdentity()
        let mac = TestIdentity()
        let grant = try TestGrantMint.grant(
            signingKey: broker, initiatorHex: phone.hex, acceptorHex: mac.hex)
        let claims = try DotGrantVerifier.verifyPairGrant(
            grant,
            keys: [broker.publicKey.rawRepresentation],
            authenticatedInitiatorHex: phone.hex,
            acceptorHex: mac.hex
        )
        #expect(claims.initiator.endpointID == phone.hex)
        #expect(claims.acceptor.platform == "mac")
    }

    @Test func wrongInitiatorIdentityRejected() throws {
        let broker = Curve25519.Signing.PrivateKey()
        let phone = TestIdentity()
        let mac = TestIdentity()
        let interloper = TestIdentity()
        let grant = try TestGrantMint.grant(
            signingKey: broker, initiatorHex: phone.hex, acceptorHex: mac.hex)
        #expect(throws: DotGrantError.identityMismatch) {
            _ = try DotGrantVerifier.verifyPairGrant(
                grant,
                keys: [broker.publicKey.rawRepresentation],
                authenticatedInitiatorHex: interloper.hex,
                acceptorHex: mac.hex
            )
        }
    }

    @Test func unknownSignerRejected() throws {
        let broker = Curve25519.Signing.PrivateKey()
        let otherKey = Curve25519.Signing.PrivateKey()
        let phone = TestIdentity()
        let mac = TestIdentity()
        let grant = try TestGrantMint.grant(
            signingKey: broker, initiatorHex: phone.hex, acceptorHex: mac.hex)
        #expect(throws: DotGrantError.invalidSignature) {
            _ = try DotGrantVerifier.verifyPairGrant(
                grant,
                keys: [otherKey.publicKey.rawRepresentation],
                authenticatedInitiatorHex: phone.hex,
                acceptorHex: mac.hex
            )
        }
    }

    @Test func expiredGrantRejected() throws {
        let broker = Curve25519.Signing.PrivateKey()
        let phone = TestIdentity()
        let mac = TestIdentity()
        let grant = try TestGrantMint.grant(
            signingKey: broker, initiatorHex: phone.hex, acceptorHex: mac.hex,
            issuedAt: Int64(Date().timeIntervalSince1970) - 7200,
            lifetime: 3600
        )
        #expect(throws: DotGrantError.expired) {
            _ = try DotGrantVerifier.verifyPairGrant(
                grant,
                keys: [broker.publicKey.rawRepresentation],
                authenticatedInitiatorHex: phone.hex,
                acceptorHex: mac.hex
            )
        }
    }
}

@Suite("E2E handshake")
struct DotHandshakeTests {
    struct Rig {
        let broker = Curve25519.Signing.PrivateKey()
        let phone = TestIdentity()
        let mac = TestIdentity()

        func grant() throws -> String {
            try TestGrantMint.grant(
                signingKey: broker, initiatorHex: phone.hex, acceptorHex: mac.hex)
        }

        var admission: DotAdmissionMaterial {
            DotAdmissionMaterial(
                grantJWS: nil,
                grantVerificationKeys: [broker.publicKey.rawRepresentation],
                expectedPeerPublicKey: nil
            )
        }
    }

    @Test func fullExchangeDerivesMatchingKeys() async throws {
        let rig = Rig()
        let initiator = try await DotHandshakeInitiator.make(
            identity: rig.phone, grantJWS: try rig.grant())
        let outcome = try await DotHandshakeResponder.respond(
            hs1Payload: initiator.hs1Payload,
            identity: rig.mac,
            admission: rig.admission,
            judge: { _ in }
        )
        #expect(outcome.peer.identityHex == rig.phone.hex)
        #expect(outcome.peer.deviceID == "11111111-1111-1111-1111-111111111111")
        #expect(outcome.peer.tag == "dotx")

        let initiated = try initiator.processHs2(
            outcome.hs2Payload, expectedPeerPublicKey: rig.mac.publicKey)
        #expect(initiated.sessionID == outcome.sessionID)

        // Keys agree: a box sealed initiator→responder opens on the responder.
        var sealer = DotSealer(key: initiated.keys.initiatorToResponder)
        var opener = DotOpener(key: outcome.keys.initiatorToResponder)
        let box = try sealer.seal(Data("proof".utf8))
        #expect(try opener.open(box) == Data("proof".utf8))
        // And the reverse direction.
        var backSealer = DotSealer(key: outcome.keys.responderToInitiator)
        var backOpener = DotOpener(key: initiated.keys.responderToInitiator)
        let backBox = try backSealer.seal(Data("mirror".utf8))
        #expect(try backOpener.open(backBox) == Data("mirror".utf8))
    }

    @Test func responderIdentityPinEnforced() async throws {
        let rig = Rig()
        let initiator = try await DotHandshakeInitiator.make(
            identity: rig.phone, grantJWS: try rig.grant())
        let outcome = try await DotHandshakeResponder.respond(
            hs1Payload: initiator.hs1Payload,
            identity: rig.mac,
            admission: rig.admission,
            judge: { _ in }
        )
        let wrongMac = TestIdentity()
        #expect(throws: DotHandshakeError.self) {
            _ = try initiator.processHs2(
                outcome.hs2Payload, expectedPeerPublicKey: wrongMac.publicKey)
        }
    }

    @Test func grantForDifferentMacDenied() async throws {
        let rig = Rig()
        let otherMac = TestIdentity()
        // Grant pins a DIFFERENT acceptor: this Mac must refuse it.
        let grant = try TestGrantMint.grant(
            signingKey: rig.broker,
            initiatorHex: rig.phone.hex,
            acceptorHex: otherMac.hex
        )
        let initiator = try await DotHandshakeInitiator.make(
            identity: rig.phone, grantJWS: grant)
        await #expect(throws: DotHandshakeError.self) {
            _ = try await DotHandshakeResponder.respond(
                hs1Payload: initiator.hs1Payload,
                identity: rig.mac,
                admission: rig.admission,
                judge: { _ in }
            )
        }
    }

    @Test func judgeCanRefuse() async throws {
        let rig = Rig()
        let initiator = try await DotHandshakeInitiator.make(
            identity: rig.phone, grantJWS: try rig.grant())
        await #expect(throws: DotHandshakeError.self) {
            _ = try await DotHandshakeResponder.respond(
                hs1Payload: initiator.hs1Payload,
                identity: rig.mac,
                admission: rig.admission,
                judge: { _ in throw DotMuxError.streamClosed }
            )
        }
    }

    @Test func tamperedHs1Rejected() async throws {
        let rig = Rig()
        let initiator = try await DotHandshakeInitiator.make(
            identity: rig.phone, grantJWS: try rig.grant())
        var tampered = initiator.hs1Payload
        // Flip a byte inside the JSON body (not the kind prefix).
        tampered[tampered.count / 2] ^= 0x01
        await #expect(throws: (any Error).self) {
            _ = try await DotHandshakeResponder.respond(
                hs1Payload: tampered,
                identity: rig.mac,
                admission: rig.admission,
                judge: { _ in }
            )
        }
    }

    @Test func denyPayloadSurfacesReason() async throws {
        let rig = Rig()
        let initiator = try await DotHandshakeInitiator.make(
            identity: rig.phone, grantJWS: try rig.grant())
        let deny = DotHandshakeDeny.payload(reason: "grant_rejected")
        do {
            _ = try initiator.processHs2(deny, expectedPeerPublicKey: nil)
            Issue.record("deny payload must throw")
        } catch DotHandshakeError.denied(let reason) {
            #expect(reason == "grant_rejected")
        }
    }
}
