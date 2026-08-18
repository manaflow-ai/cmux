import CMUXMobileCore
import CryptoKit
import Foundation
import Testing
@testable import CmuxPeerTransport

/// Grant and attestation verification against the unchanged server wire
/// format: Ed25519 JWTs with exact claim sets bound to device IDs,
/// EndpointIDs, identity generations, the signed ALPN, expiry, and grant ID.
@Suite
struct PeerGrantVerifierTests {
    @Test
    func pairGrantBindsSignatureTimePlatformAndExactPeers() throws {
        let fixture = try GrantFixture()
        let token = try fixture.pairGrant(expiresAt: fixture.nowSeconds + 3_600)

        let claims = try PeerGrantVerifier().verifyPairGrant(
            token,
            keys: fixture.keySet,
            initiator: fixture.initiator,
            acceptor: fixture.acceptor,
            now: fixture.now
        )
        #expect(claims.initiator.platform == .ios)
        #expect(claims.acceptor.platform == .mac)
        #expect(claims.grantID == GrantFixture.grantID)

        let liveClaims = try PeerGrantVerifier().verifyPairGrant(
            token,
            keys: fixture.keySet,
            authenticatedInitiatorID: fixture.initiator.endpointID,
            acceptor: fixture.acceptor,
            now: fixture.now
        )
        #expect(liveClaims.initiator == fixture.initiator)
    }

    @Test
    func pairGrantRejectsAWrongBindingTuple() throws {
        let fixture = try GrantFixture()
        let token = try fixture.pairGrant(expiresAt: fixture.nowSeconds + 3_600)

        let otherAcceptor = PeerGrantPeer(
            bindingID: fixture.acceptor.bindingID,
            deviceID: fixture.acceptor.deviceID,
            tag: "other",
            platform: .mac,
            endpointID: fixture.acceptor.endpointID,
            identityGeneration: fixture.acceptor.identityGeneration
        )
        #expect(throws: PeerGrantVerifierError.identityMismatch) {
            try PeerGrantVerifier().verifyPairGrant(
                token,
                keys: fixture.keySet,
                initiator: fixture.initiator,
                acceptor: otherAcceptor,
                now: fixture.now
            )
        }
        #expect(throws: PeerGrantVerifierError.identityMismatch) {
            try PeerGrantVerifier().verifyPairGrant(
                token,
                keys: fixture.keySet,
                authenticatedInitiatorID: fixture.acceptor.endpointID,
                acceptor: fixture.acceptor,
                now: fixture.now
            )
        }
        let wrongGeneration = PeerGrantPeer(
            bindingID: fixture.initiator.bindingID,
            deviceID: fixture.initiator.deviceID,
            tag: fixture.initiator.tag,
            platform: .ios,
            endpointID: fixture.initiator.endpointID,
            identityGeneration: fixture.initiator.identityGeneration + 1
        )
        #expect(throws: PeerGrantVerifierError.identityMismatch) {
            try PeerGrantVerifier().verifyPairGrant(
                token,
                keys: fixture.keySet,
                initiator: wrongGeneration,
                acceptor: fixture.acceptor,
                now: fixture.now
            )
        }
    }

    @Test
    func tamperedSignatureAndExpiryFailClosed() throws {
        let fixture = try GrantFixture()
        let valid = try fixture.pairGrant(expiresAt: fixture.nowSeconds + 60)
        var segments = valid.split(separator: ".").map(String.init)
        let replacement = segments[2].first == "A" ? "B" : "A"
        segments[2].replaceSubrange(
            segments[2].startIndex ... segments[2].startIndex,
            with: replacement
        )
        let tampered = segments.joined(separator: ".")
        #expect(throws: PeerGrantVerifierError.invalidSignature) {
            try PeerGrantVerifier().verifyPairGrant(
                tampered,
                keys: fixture.keySet,
                initiator: fixture.initiator,
                acceptor: fixture.acceptor,
                now: fixture.now
            )
        }

        let expired = try fixture.pairGrant(expiresAt: fixture.nowSeconds)
        #expect(throws: PeerGrantVerifierError.expired) {
            try PeerGrantVerifier().verifyPairGrant(
                expired,
                keys: fixture.keySet,
                initiator: fixture.initiator,
                acceptor: fixture.acceptor,
                now: fixture.now
            )
        }
    }

    @Test
    func grantSignedByAKeyOutsideTheSetIsRejected() throws {
        let fixture = try GrantFixture()
        let token = try fixture.pairGrant(expiresAt: fixture.nowSeconds + 60)

        // Same kid, different public key: the signature check fails.
        let otherKey = Curve25519.Signing.PrivateKey()
        let substitutedSet = PeerGrantVerificationKeySet(
            version: 1,
            currentKeyID: "current",
            keys: [
                PeerGrantVerificationKey(
                    kid: "current",
                    alg: "EdDSA",
                    spkiDerBase64: (GrantFixture.spkiPrefix
                        + otherKey.publicKey.rawRepresentation).base64EncodedString()
                ),
            ]
        )
        #expect(throws: PeerGrantVerifierError.invalidSignature) {
            try PeerGrantVerifier().verifyPairGrant(
                token,
                keys: substitutedSet,
                initiator: fixture.initiator,
                acceptor: fixture.acceptor,
                now: fixture.now
            )
        }

        // Unknown kid: rejected before any signature use.
        let renamedSet = PeerGrantVerificationKeySet(
            version: 1,
            currentKeyID: "rotated",
            keys: [
                PeerGrantVerificationKey(
                    kid: "rotated",
                    alg: "EdDSA",
                    spkiDerBase64: fixture.keySet.keys[0].spkiDerBase64
                ),
            ]
        )
        #expect(throws: PeerGrantVerifierError.unknownKeyID) {
            try PeerGrantVerifier().verifyPairGrant(
                token,
                keys: renamedSet,
                initiator: fixture.initiator,
                acceptor: fixture.acceptor,
                now: fixture.now
            )
        }

        // Wrong algorithm: rejected as an invalid key set.
        let wrongAlgorithm = PeerGrantVerificationKeySet(
            version: 1,
            currentKeyID: "current",
            keys: [
                PeerGrantVerificationKey(
                    kid: "current",
                    alg: "ES256",
                    spkiDerBase64: fixture.keySet.keys[0].spkiDerBase64
                ),
            ]
        )
        #expect(throws: PeerGrantVerifierError.invalidKeySet) {
            try PeerGrantVerifier().verifyPairGrant(
                token,
                keys: wrongAlgorithm,
                initiator: fixture.initiator,
                acceptor: fixture.acceptor,
                now: fixture.now
            )
        }
    }

    @Test
    func extraOrMissingClaimKeysAreRejected() throws {
        let fixture = try GrantFixture()
        var claims = fixture.pairGrantClaims(expiresAt: fixture.nowSeconds + 60)
        claims["extra"] = "value"
        let extra = try fixture.token(type: "cmux-pair-grant+jwt", claims: claims)
        #expect(throws: PeerGrantVerifierError.invalidClaims) {
            try PeerGrantVerifier().verifyPairGrant(
                extra,
                keys: fixture.keySet,
                initiator: fixture.initiator,
                acceptor: fixture.acceptor,
                now: fixture.now
            )
        }
    }

    @Test
    func offlinePairRequiresDistinctEndpointsAndConstantAccountSubject() throws {
        let fixture = try GrantFixture()
        let subject = BrokerFixtures.base64URL(Data(repeating: 7, count: 32))
        let initiatorToken = try fixture.attestation(
            expectation: fixture.initiatorExpectation,
            subject: subject
        )
        let acceptorToken = try fixture.attestation(
            expectation: fixture.acceptorExpectation,
            subject: subject
        )
        let pair = try PeerGrantVerifier().verifyOfflineSameAccountPair(
            initiatorToken: initiatorToken,
            acceptorToken: acceptorToken,
            keys: fixture.keySet,
            initiator: fixture.initiatorExpectation,
            acceptor: fixture.acceptorExpectation,
            now: fixture.now
        )
        #expect(pair.initiator.accountSubject == pair.acceptor.accountSubject)

        let otherSubject = BrokerFixtures.base64URL(Data(repeating: 8, count: 32))
        let mismatched = try fixture.attestation(
            expectation: fixture.acceptorExpectation,
            subject: otherSubject
        )
        #expect(throws: PeerGrantVerifierError.accountMismatch) {
            try PeerGrantVerifier().verifyOfflineSameAccountPair(
                initiatorToken: initiatorToken,
                acceptorToken: mismatched,
                keys: fixture.keySet,
                initiator: fixture.initiatorExpectation,
                acceptor: fixture.acceptorExpectation,
                now: fixture.now
            )
        }
    }
}

struct GrantFixture {
    static let grantID = "123e4567-e89b-42d3-a456-426614174010"
    static let spkiPrefix = Data([
        0x30, 0x2a, 0x30, 0x05, 0x06, 0x03,
        0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
    ])

    let privateKey: Curve25519.Signing.PrivateKey
    let keySet: PeerGrantVerificationKeySet
    let initiator: PeerGrantPeer
    let acceptor: PeerGrantPeer
    let initiatorExpectation: PeerEndpointExpectation
    let acceptorExpectation: PeerEndpointExpectation
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let nowSeconds: Int64 = 1_800_000_000

    init() throws {
        privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: BrokerFixtures.secretBytes
        )
        keySet = PeerGrantVerificationKeySet(
            version: 1,
            currentKeyID: "current",
            keys: [
                PeerGrantVerificationKey(
                    kid: "current",
                    alg: "EdDSA",
                    spkiDerBase64: (Self.spkiPrefix
                        + privateKey.publicKey.rawRepresentation).base64EncodedString()
                ),
            ]
        )
        let initiatorID = try CmxIrohPeerIdentity(
            endpointID: BrokerFixtures.endpointID
        )
        let acceptorKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 9, count: 32)
        )
        let acceptorID = try CmxIrohPeerIdentity(
            endpointID: acceptorKey.publicKey.rawRepresentation
                .map { String(format: "%02x", $0) }
                .joined()
        )
        initiator = PeerGrantPeer(
            bindingID: "123e4567-e89b-42d3-a456-426614174001",
            deviceID: "123e4567-e89b-42d3-a456-426614174002",
            tag: "stable",
            platform: .ios,
            endpointID: initiatorID,
            identityGeneration: 1
        )
        acceptor = PeerGrantPeer(
            bindingID: "123e4567-e89b-42d3-a456-426614174003",
            deviceID: "123e4567-e89b-42d3-a456-426614174004",
            tag: "stable",
            platform: .mac,
            endpointID: acceptorID,
            identityGeneration: 2
        )
        initiatorExpectation = PeerEndpointExpectation(
            bindingID: initiator.bindingID,
            deviceID: initiator.deviceID,
            endpointID: initiator.endpointID,
            identityGeneration: initiator.identityGeneration,
            platform: initiator.platform
        )
        acceptorExpectation = PeerEndpointExpectation(
            bindingID: acceptor.bindingID,
            deviceID: acceptor.deviceID,
            endpointID: acceptor.endpointID,
            identityGeneration: acceptor.identityGeneration,
            platform: acceptor.platform
        )
    }

    func pairGrantClaims(expiresAt: Int64) -> [String: Any] {
        [
            "jti": Self.grantID,
            "iat": nowSeconds,
            "nbf": nowSeconds - 5,
            "exp": expiresAt,
            "alpn": "cmux/mobile/1",
            "scope": "cmux.mobile.attach",
            "initiator": Self.peerObject(initiator),
            "acceptor": Self.peerObject(acceptor),
        ]
    }

    func pairGrant(expiresAt: Int64) throws -> String {
        try token(
            type: "cmux-pair-grant+jwt",
            claims: pairGrantClaims(expiresAt: expiresAt)
        )
    }

    func pairGrant(initiator: PeerGrantPeer, acceptor: PeerGrantPeer, expiresAt: Int64) throws -> String {
        var claims = pairGrantClaims(expiresAt: expiresAt)
        claims["initiator"] = Self.peerObject(initiator)
        claims["acceptor"] = Self.peerObject(acceptor)
        return try token(type: "cmux-pair-grant+jwt", claims: claims)
    }

    func attestation(
        expectation: PeerEndpointExpectation,
        subject: String
    ) throws -> String {
        let claims: [String: Any] = [
            "version": 1,
            "jti": UUID().uuidString.lowercased(),
            "sub": subject,
            "bindingId": expectation.bindingID,
            "deviceId": expectation.deviceID,
            "endpointId": expectation.endpointID.endpointID,
            "identityGeneration": expectation.identityGeneration,
            "platform": expectation.platform.rawValue,
            "iat": nowSeconds,
            "nbf": nowSeconds - 5,
            "exp": nowSeconds + 3_600,
            "alpn": "cmux/mobile/1",
            "scope": "cmux.offline-pair.same-account",
        ]
        return try token(type: "cmux-endpoint-attestation-v1+jwt", claims: claims)
    }

    func token(type: String, claims: [String: Any]) throws -> String {
        let header = BrokerFixtures.base64URL(
            try JSONSerialization.data(
                withJSONObject: ["alg": "EdDSA", "typ": type, "kid": "current"],
                options: [.sortedKeys]
            )
        )
        let body = BrokerFixtures.base64URL(
            try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
        )
        let input = "\(header).\(body)"
        let signature = BrokerFixtures.base64URL(
            try privateKey.signature(for: Data(input.utf8))
        )
        return "\(input).\(signature)"
    }

    private static func peerObject(_ peer: PeerGrantPeer) -> [String: Any] {
        [
            "bindingId": peer.bindingID,
            "deviceId": peer.deviceID,
            "tag": peer.tag,
            "platform": peer.platform.rawValue,
            "endpointId": peer.endpointID.endpointID,
            "identityGeneration": peer.identityGeneration,
        ]
    }
}
