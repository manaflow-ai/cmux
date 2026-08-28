import CryptoKit
import Foundation
import Testing

@testable import CmuxDorTransport

@Suite("sealing")
struct DorSealingTests {
    private func keyPair() -> (DorSealer, DorOpener) {
        let key = SymmetricKey(size: .bits256)
        return (DorSealer(key: key), DorOpener(key: key))
    }

    @Test func roundTripAndCounterMonotonicity() throws {
        var (sealer, opener) = keyPair()
        let first = try sealer.seal(Data("one".utf8))
        let second = try sealer.seal(Data("two".utf8))
        #expect(try opener.open(first) == Data("one".utf8))
        #expect(try opener.open(second) == Data("two".utf8))
        // Replaying an already-opened box is rejected.
        #expect(throws: DorCryptoError.self) {
            var replayOpener = opener
            _ = try replayOpener.open(first)
        }
    }

    @Test func reorderRejected() throws {
        var (sealer, opener) = keyPair()
        let first = try sealer.seal(Data("one".utf8))
        let second = try sealer.seal(Data("two".utf8))
        _ = try opener.open(second)
        #expect(throws: DorCryptoError.self) { _ = try opener.open(first) }
    }

    @Test func tamperRejected() throws {
        var (sealer, opener) = keyPair()
        var sealed = try sealer.seal(Data("payload".utf8))
        sealed[sealed.count - 1] ^= 0xFF
        #expect(throws: DorCryptoError.self) { _ = try opener.open(sealed) }
    }

    @Test func wrongKeyRejected() throws {
        var (sealer, _) = keyPair()
        var strangerOpener = DorOpener(key: SymmetricKey(size: .bits256))
        let sealed = try sealer.seal(Data("payload".utf8))
        #expect(throws: DorCryptoError.self) { _ = try strangerOpener.open(sealed) }
    }

    @Test func bothSidesDeriveTheSameDirectionalKeys() throws {
        let initiatorEph = Curve25519.KeyAgreement.PrivateKey()
        let responderEph = Curve25519.KeyAgreement.PrivateKey()
        let hs1 = Data("hs1-json-bytes".utf8)
        let hs2 = Data("hs2-json-bytes".utf8)
        let initiatorKeys = DorSessionKeys(
            sharedSecret: try initiatorEph.sharedSecretFromKeyAgreement(
                with: responderEph.publicKey),
            hs1Bytes: hs1, hs2Bytes: hs2)
        let responderKeys = DorSessionKeys(
            sharedSecret: try responderEph.sharedSecretFromKeyAgreement(
                with: initiatorEph.publicKey),
            hs1Bytes: hs1, hs2Bytes: hs2)
        // initiator seals i2r, responder opens i2r; and the reverse.
        var i2rSealer = DorSealer(key: initiatorKeys.initiatorToResponder)
        var i2rOpener = DorOpener(key: responderKeys.initiatorToResponder)
        #expect(try i2rOpener.open(try i2rSealer.seal(Data("up".utf8))) == Data("up".utf8))
        var r2iSealer = DorSealer(key: responderKeys.responderToInitiator)
        var r2iOpener = DorOpener(key: initiatorKeys.responderToInitiator)
        #expect(try r2iOpener.open(try r2iSealer.seal(Data("down".utf8))) == Data("down".utf8))
        // Directions are distinct keys: opening up-traffic with the down key fails.
        var crossOpener = DorOpener(key: initiatorKeys.responderToInitiator)
        var upSealer = DorSealer(key: initiatorKeys.initiatorToResponder)
        #expect(throws: DorCryptoError.self) {
            _ = try crossOpener.open(try upSealer.seal(Data("x".utf8)))
        }
    }

    @Test func transcriptBindsEverySignedField() {
        let eph = Data(repeating: 1, count: 32)
        let identity = Data(repeating: 2, count: 32)
        let base = DorTranscript.hs1Message(eph: eph, identity: identity, grantJWS: "grant")
        #expect(base != DorTranscript.hs1Message(eph: identity, identity: eph, grantJWS: "grant"))
        #expect(base != DorTranscript.hs1Message(eph: eph, identity: identity, grantJWS: "other"))
        let hs2 = DorTranscript.hs2Message(
            responderEph: eph, initiatorEph: identity,
            responderIdentity: eph, session: "s1")
        #expect(hs2 != DorTranscript.hs2Message(
            responderEph: eph, initiatorEph: identity,
            responderIdentity: eph, session: "s2"))
    }
}

@Suite("pair grant verification")
struct DorGrantTests {
    /// Mint a broker-shaped grant with a throwaway Ed25519 key.
    private func mint(
        signingKey: Curve25519.Signing.PrivateKey,
        initiatorHex: String,
        acceptorHex: String,
        issuedAt: Int64 = Int64(Date().timeIntervalSince1970) - 10,
        lifetime: Int64 = 3600,
        mutate: ((inout [String: Any]) -> Void)? = nil
    ) throws -> String {
        let header: [String: Any] = ["alg": "EdDSA", "typ": "cmux-pair-grant+jwt", "kid": "k1"]
        var claims: [String: Any] = [
            "jti": UUID().uuidString.lowercased(),
            "iat": issuedAt,
            "nbf": issuedAt,
            "exp": issuedAt + lifetime,
            "alpn": "cmux/mobile/1",
            "scope": "cmux.mobile.attach",
            "initiator": [
                "bindingId": UUID().uuidString.lowercased(),
                "deviceId": UUID().uuidString.lowercased(),
                "tag": "dor",
                "platform": "ios",
                "endpointId": initiatorHex,
                "identityGeneration": 1,
            ],
            "acceptor": [
                "bindingId": UUID().uuidString.lowercased(),
                "deviceId": UUID().uuidString.lowercased(),
                "tag": "dor",
                "platform": "mac",
                "endpointId": acceptorHex,
                "identityGeneration": 1,
            ],
        ]
        mutate?(&claims)
        func b64url(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let headerPart = b64url(try JSONSerialization.data(withJSONObject: header))
        let claimsPart = b64url(try JSONSerialization.data(withJSONObject: claims))
        let signature = try signingKey.signature(for: Data("\(headerPart).\(claimsPart)".utf8))
        return "\(headerPart).\(claimsPart).\(b64url(signature))"
    }

    @Test func verifiesAndPinsTuple() throws {
        let broker = Curve25519.Signing.PrivateKey()
        let initiatorHex = Data(repeating: 0xAB, count: 32).lowercaseHex
        let acceptorHex = Data(repeating: 0xCD, count: 32).lowercaseHex
        let token = try mint(
            signingKey: broker, initiatorHex: initiatorHex, acceptorHex: acceptorHex)
        let claims = try DorGrantVerifier.verifyPairGrant(
            token,
            keys: [broker.publicKey.rawRepresentation],
            authenticatedInitiatorHex: initiatorHex,
            acceptorHex: acceptorHex
        )
        #expect(claims.initiator.endpointID == initiatorHex)
        #expect(claims.acceptor.platform == "mac")
    }

    @Test func rejectsWrongInitiatorAndForeignKeyAndExpiry() throws {
        let broker = Curve25519.Signing.PrivateKey()
        let initiatorHex = Data(repeating: 0xAB, count: 32).lowercaseHex
        let acceptorHex = Data(repeating: 0xCD, count: 32).lowercaseHex
        let token = try mint(
            signingKey: broker, initiatorHex: initiatorHex, acceptorHex: acceptorHex)

        // A different authenticated initiator must not pass tuple pinning.
        #expect(throws: DorGrantError.self) {
            _ = try DorGrantVerifier.verifyPairGrant(
                token, keys: [broker.publicKey.rawRepresentation],
                authenticatedInitiatorHex: acceptorHex, acceptorHex: acceptorHex)
        }
        // A signature under an unpinned key fails closed.
        #expect(throws: DorGrantError.self) {
            _ = try DorGrantVerifier.verifyPairGrant(
                token, keys: [Curve25519.Signing.PrivateKey().publicKey.rawRepresentation],
                authenticatedInitiatorHex: initiatorHex, acceptorHex: acceptorHex)
        }
        // Expired grants fail.
        let expired = try mint(
            signingKey: broker, initiatorHex: initiatorHex, acceptorHex: acceptorHex,
            issuedAt: Int64(Date().timeIntervalSince1970) - 7200, lifetime: 3600)
        #expect(throws: DorGrantError.self) {
            _ = try DorGrantVerifier.verifyPairGrant(
                expired, keys: [broker.publicKey.rawRepresentation],
                authenticatedInitiatorHex: initiatorHex, acceptorHex: acceptorHex)
        }
    }

    @Test func rejectsUnexpectedClaimShape() throws {
        let broker = Curve25519.Signing.PrivateKey()
        let initiatorHex = Data(repeating: 0xAB, count: 32).lowercaseHex
        let acceptorHex = Data(repeating: 0xCD, count: 32).lowercaseHex
        let extraKey = try mint(
            signingKey: broker, initiatorHex: initiatorHex, acceptorHex: acceptorHex
        ) { claims in
            claims["surprise"] = true
        }
        #expect(throws: DorGrantError.self) {
            _ = try DorGrantVerifier.verifyPairGrant(
                extraKey, keys: [broker.publicKey.rawRepresentation],
                authenticatedInitiatorHex: initiatorHex, acceptorHex: acceptorHex)
        }
        let wrongScope = try mint(
            signingKey: broker, initiatorHex: initiatorHex, acceptorHex: acceptorHex
        ) { claims in
            claims["scope"] = "cmux.other"
        }
        #expect(throws: DorGrantError.self) {
            _ = try DorGrantVerifier.verifyPairGrant(
                wrongScope, keys: [broker.publicKey.rawRepresentation],
                authenticatedInitiatorHex: initiatorHex, acceptorHex: acceptorHex)
        }
    }

    @Test func routingDecodeNeedsNoKeys() throws {
        let broker = Curve25519.Signing.PrivateKey()
        let initiatorHex = Data(repeating: 0xAB, count: 32).lowercaseHex
        let acceptorHex = Data(repeating: 0xCD, count: 32).lowercaseHex
        let token = try mint(
            signingKey: broker, initiatorHex: initiatorHex, acceptorHex: acceptorHex)
        let claims = try #require(DorGrantVerifier.decodeClaimsForRouting(token))
        #expect(claims.acceptor.endpointID == acceptorHex)
    }
}
