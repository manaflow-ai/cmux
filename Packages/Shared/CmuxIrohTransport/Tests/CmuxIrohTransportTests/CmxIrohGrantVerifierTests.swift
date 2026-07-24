import CryptoKit
import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohGrantVerifierTests {
    @Test
    func pairGrantBindsSignatureTimePlatformAndExactPeers() throws {
        let fixture = try Fixture()
        let token = try fixture.pairGrant(expiresAt: fixture.nowSeconds + 3_600)

        let claims = try CmxIrohGrantVerifier().verifyPairGrant(
            token,
            keys: fixture.keySet,
            initiator: fixture.initiator,
            acceptor: fixture.acceptor,
            now: fixture.now
        )
        #expect(claims.initiator.platform == .ios)
        #expect(claims.acceptor.platform == .mac)
        let liveClaims = try CmxIrohGrantVerifier().verifyPairGrant(
            token,
            keys: fixture.keySet,
            authenticatedInitiatorID: fixture.initiator.endpointID,
            acceptor: fixture.acceptor,
            now: fixture.now
        )
        #expect(liveClaims.initiator == fixture.initiator)

        let otherAcceptor = CmxIrohGrantPeer(
            bindingID: fixture.acceptor.bindingID,
            deviceID: fixture.acceptor.deviceID,
            tag: "other",
            platform: .mac,
            endpointID: fixture.acceptor.endpointID,
            identityGeneration: fixture.acceptor.identityGeneration
        )
        #expect(throws: CmxIrohGrantVerifierError.identityMismatch) {
            try CmxIrohGrantVerifier().verifyPairGrant(
                token,
                keys: fixture.keySet,
                initiator: fixture.initiator,
                acceptor: otherAcceptor,
                now: fixture.now
            )
        }
        #expect(throws: CmxIrohGrantVerifierError.identityMismatch) {
            try CmxIrohGrantVerifier().verifyPairGrant(
                token,
                keys: fixture.keySet,
                authenticatedInitiatorID: fixture.acceptor.endpointID,
                acceptor: fixture.acceptor,
                now: fixture.now
            )
        }
    }

    @Test
    func tamperingAndExpiryFailClosed() throws {
        let fixture = try Fixture()
        let valid = try fixture.pairGrant(expiresAt: fixture.nowSeconds + 60)
        var segments = valid.split(separator: ".").map(String.init)
        let replacement = segments[2].first == "A" ? "B" : "A"
        segments[2].replaceSubrange(segments[2].startIndex ... segments[2].startIndex, with: replacement)
        let tampered = segments.joined(separator: ".")
        #expect(throws: CmxIrohGrantVerifierError.invalidSignature) {
            try CmxIrohGrantVerifier().verifyPairGrant(
                tampered,
                keys: fixture.keySet,
                initiator: fixture.initiator,
                acceptor: fixture.acceptor,
                now: fixture.now
            )
        }

        let expired = try fixture.pairGrant(expiresAt: fixture.nowSeconds)
        #expect(throws: CmxIrohGrantVerifierError.expired) {
            try CmxIrohGrantVerifier().verifyPairGrant(
                expired,
                keys: fixture.keySet,
                initiator: fixture.initiator,
                acceptor: fixture.acceptor,
                now: fixture.now
            )
        }
    }

    @Test
    func offlinePairRequiresDistinctEndpointsAndConstantAccountSubject() throws {
        let fixture = try Fixture()
        let subject = Data(repeating: 7, count: 32).base64URL
        let initiatorToken = try fixture.attestation(
            expectation: fixture.initiatorExpectation,
            subject: subject
        )
        let acceptorToken = try fixture.attestation(
            expectation: fixture.acceptorExpectation,
            subject: subject
        )
        let pair = try CmxIrohGrantVerifier().verifyOfflineSameAccountPair(
            initiatorToken: initiatorToken,
            acceptorToken: acceptorToken,
            keys: fixture.keySet,
            initiator: fixture.initiatorExpectation,
            acceptor: fixture.acceptorExpectation,
            now: fixture.now
        )
        #expect(pair.initiator.accountSubject == pair.acceptor.accountSubject)

        let otherSubject = Data(repeating: 8, count: 32).base64URL
        let mismatched = try fixture.attestation(
            expectation: fixture.acceptorExpectation,
            subject: otherSubject
        )
        #expect(throws: CmxIrohGrantVerifierError.accountMismatch) {
            try CmxIrohGrantVerifier().verifyOfflineSameAccountPair(
                initiatorToken: initiatorToken,
                acceptorToken: mismatched,
                keys: fixture.keySet,
                initiator: fixture.initiatorExpectation,
                acceptor: fixture.acceptorExpectation,
                now: fixture.now
            )
        }
    }

    @Test
    func keySetRejectsWrongAlgorithmBeforeSignatureUse() throws {
        let fixture = try Fixture()
        let badKey = CmxIrohGrantVerificationKey(
            kid: fixture.keySet.keys[0].kid,
            alg: "ES256",
            spkiDerBase64: fixture.keySet.keys[0].spkiDerBase64
        )
        let badSet = CmxIrohGrantVerificationKeySet(
            version: 1,
            currentKeyID: "current",
            keys: [badKey]
        )
        let token = try fixture.pairGrant(expiresAt: fixture.nowSeconds + 60)
        #expect(throws: CmxIrohGrantVerifierError.invalidKeySet) {
            try CmxIrohGrantVerifier().verifyPairGrant(
                token,
                keys: badSet,
                initiator: fixture.initiator,
                acceptor: fixture.acceptor,
                now: fixture.now
            )
        }
    }
}

private struct Fixture {
    let privateKey: Curve25519.Signing.PrivateKey
    let keySet: CmxIrohGrantVerificationKeySet
    let initiator: CmxIrohGrantPeer
    let acceptor: CmxIrohGrantPeer
    let initiatorExpectation: CmxIrohEndpointExpectation
    let acceptorExpectation: CmxIrohEndpointExpectation
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let nowSeconds: Int64 = 1_800_000_000

    init() throws {
        privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data((0 ..< 32).map(UInt8.init))
        )
        let prefix = Data([
            0x30, 0x2a, 0x30, 0x05, 0x06, 0x03,
            0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
        ])
        let key = CmxIrohGrantVerificationKey(
            kid: "current",
            alg: "EdDSA",
            spkiDerBase64: (prefix + privateKey.publicKey.rawRepresentation).base64EncodedString()
        )
        keySet = CmxIrohGrantVerificationKeySet(
            version: 1,
            currentKeyID: "current",
            keys: [key]
        )
        let initiatorID = try CmxIrohPeerIdentity(
            endpointID: privateKey.publicKey.rawRepresentation.hex
        )
        let acceptorKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 9, count: 32)
        )
        let acceptorID = try CmxIrohPeerIdentity(
            endpointID: acceptorKey.publicKey.rawRepresentation.hex
        )
        initiator = CmxIrohGrantPeer(
            bindingID: "123e4567-e89b-42d3-a456-426614174001",
            deviceID: "123e4567-e89b-42d3-a456-426614174002",
            tag: "stable",
            platform: .ios,
            endpointID: initiatorID,
            identityGeneration: 1
        )
        acceptor = CmxIrohGrantPeer(
            bindingID: "123e4567-e89b-42d3-a456-426614174003",
            deviceID: "123e4567-e89b-42d3-a456-426614174004",
            tag: "stable",
            platform: .mac,
            endpointID: acceptorID,
            identityGeneration: 2
        )
        initiatorExpectation = CmxIrohEndpointExpectation(
            bindingID: initiator.bindingID,
            deviceID: initiator.deviceID,
            endpointID: initiator.endpointID,
            identityGeneration: initiator.identityGeneration,
            platform: initiator.platform
        )
        acceptorExpectation = CmxIrohEndpointExpectation(
            bindingID: acceptor.bindingID,
            deviceID: acceptor.deviceID,
            endpointID: acceptor.endpointID,
            identityGeneration: acceptor.identityGeneration,
            platform: acceptor.platform
        )
    }

    func pairGrant(expiresAt: Int64) throws -> String {
        let claims: [String: Any] = [
            "jti": "123e4567-e89b-42d3-a456-426614174010",
            "iat": nowSeconds,
            "nbf": nowSeconds - 5,
            "exp": expiresAt,
            "alpn": "cmux/mobile/1",
            "scope": "cmux.mobile.attach",
            "initiator": peerObject(initiator),
            "acceptor": peerObject(acceptor),
        ]
        return try token(type: "cmux-pair-grant+jwt", claims: claims)
    }

    func attestation(
        expectation: CmxIrohEndpointExpectation,
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

    private func token(type: String, claims: [String: Any]) throws -> String {
        let header = try JSONSerialization.data(
            withJSONObject: ["alg": "EdDSA", "typ": type, "kid": "current"],
            options: [.sortedKeys]
        ).base64URL
        let body = try JSONSerialization.data(
            withJSONObject: claims,
            options: [.sortedKeys]
        ).base64URL
        let input = "\(header).\(body)"
        let signature = try privateKey.signature(for: Data(input.utf8)).base64URL
        return "\(input).\(signature)"
    }

    private func peerObject(_ peer: CmxIrohGrantPeer) -> [String: Any] {
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

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
