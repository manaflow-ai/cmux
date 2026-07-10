import CMUXMobileCore
import CryptoKit
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohOfflinePairingSessionsTests {
    @Test
    func validInvitationIsConsumedExactlyOnce() async throws {
        let fixture = try OfflineFixture()
        let sessions = fixture.sessions()
        let invitation = try await fixture.invitation(from: sessions)
        let credential = try invitation.admissionCredential(
            initiatorAttestation: try fixture.initiatorAttestation()
        )

        let verified = try await sessions.verifyAndConsume(
            credential: credential,
            authenticatedPeerID: fixture.initiator.endpointID,
            now: fixture.now
        )
        #expect(verified.initiator.endpointID == fixture.initiator.endpointID)
        await #expect(throws: CmxIrohOfflinePairingSessionError.sessionUnavailable) {
            try await sessions.verifyAndConsume(
                credential: credential,
                authenticatedPeerID: fixture.initiator.endpointID,
                now: fixture.now
            )
        }
    }

    @Test
    func qrPossessionWithoutAnIndependentInitiatorAttestationFails() async throws {
        let fixture = try OfflineFixture()
        let sessions = fixture.sessions()
        let invitation = try await fixture.invitation(from: sessions)
        let copiedMacCredential = try invitation.admissionCredential(
            initiatorAttestation: invitation.acceptorAttestation
        )

        await #expect(throws: CmxIrohGrantVerifierError.identityMismatch) {
            try await sessions.verifyAndConsume(
                credential: copiedMacCredential,
                authenticatedPeerID: fixture.initiator.endpointID,
                now: fixture.now
            )
        }
    }

    @Test
    func wrongProofDoesNotConsumeTheInvitation() async throws {
        let fixture = try OfflineFixture()
        let sessions = fixture.sessions()
        let invitation = try await fixture.invitation(from: sessions)
        let initiatorAttestation = try fixture.initiatorAttestation()
        let wrong = try CmxIrohAdmissionCredential.offlinePairing(
            endpointAttestation: initiatorAttestation,
            invitationID: CmxIrohResourceID(invitation.sessionID),
            proof: Data(repeating: 0xff, count: 32)
        )
        await #expect(throws: CmxIrohOfflinePairingSessionError.invalidProof) {
            try await sessions.verifyAndConsume(
                credential: wrong,
                authenticatedPeerID: fixture.initiator.endpointID,
                now: fixture.now
            )
        }

        let correct = try invitation.admissionCredential(
            initiatorAttestation: initiatorAttestation
        )
        _ = try await sessions.verifyAndConsume(
            credential: correct,
            authenticatedPeerID: fixture.initiator.endpointID,
            now: fixture.now
        )
    }

    @Test
    func concurrentReplayHasOneWinner() async throws {
        let fixture = try OfflineFixture()
        let sessions = fixture.sessions()
        let invitation = try await fixture.invitation(from: sessions)
        let credential = try invitation.admissionCredential(
            initiatorAttestation: try fixture.initiatorAttestation()
        )

        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0 ..< 2 {
                group.addTask {
                    do {
                        _ = try await sessions.verifyAndConsume(
                            credential: credential,
                            authenticatedPeerID: fixture.initiator.endpointID,
                            now: fixture.now
                        )
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var count = 0
            for await value in group where value { count += 1 }
            return count
        }
        #expect(successes == 1)
    }

    @Test
    func previousRotationKeyRemainsValidForCachedAttestations() async throws {
        let fixture = try OfflineFixture(signingKey: .previous)
        let sessions = fixture.sessions()
        let invitation = try await fixture.invitation(from: sessions)
        let credential = try invitation.admissionCredential(
            initiatorAttestation: try fixture.initiatorAttestation()
        )
        _ = try await sessions.verifyAndConsume(
            credential: credential,
            authenticatedPeerID: fixture.initiator.endpointID,
            now: fixture.now
        )
    }

    @Test
    func liveTLSIdentitySubstitutionFailsWithoutConsuming() async throws {
        let fixture = try OfflineFixture()
        let sessions = fixture.sessions()
        let invitation = try await fixture.invitation(from: sessions)
        let credential = try invitation.admissionCredential(
            initiatorAttestation: try fixture.initiatorAttestation()
        )
        await #expect(throws: CmxIrohGrantVerifierError.identityMismatch) {
            try await sessions.verifyAndConsume(
                credential: credential,
                authenticatedPeerID: fixture.acceptor.endpointID,
                now: fixture.now
            )
        }
        _ = try await sessions.verifyAndConsume(
            credential: credential,
            authenticatedPeerID: fixture.initiator.endpointID,
            now: fixture.now
        )
    }
}

private struct OfflineFixture: Sendable {
    enum SigningKey { case current, previous }

    let currentKey: Curve25519.Signing.PrivateKey
    let previousKey: Curve25519.Signing.PrivateKey
    let signingKey: SigningKey
    let keySet: CmxIrohGrantVerificationKeySet
    let initiator: CmxIrohEndpointExpectation
    let acceptor: CmxIrohEndpointExpectation
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let nowSeconds: Int64 = 1_800_000_000

    init(signingKey: SigningKey = .current) throws {
        currentKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data((0 ..< 32).map(UInt8.init))
        )
        previousKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 3, count: 32)
        )
        self.signingKey = signingKey
        keySet = CmxIrohGrantVerificationKeySet(
            version: 1,
            currentKeyID: "current",
            keys: [
                Self.verificationKey(id: "current", key: currentKey),
                Self.verificationKey(id: "previous", key: previousKey),
            ]
        )
        initiator = CmxIrohEndpointExpectation(
            bindingID: "123e4567-e89b-42d3-a456-426614174001",
            deviceID: "123e4567-e89b-42d3-a456-426614174002",
            endpointID: try CmxIrohPeerIdentity(
                endpointID: currentKey.publicKey.rawRepresentation.hex
            ),
            identityGeneration: 1,
            platform: .ios
        )
        let macKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 9, count: 32)
        )
        acceptor = CmxIrohEndpointExpectation(
            bindingID: "123e4567-e89b-42d3-a456-426614174003",
            deviceID: "123e4567-e89b-42d3-a456-426614174004",
            endpointID: try CmxIrohPeerIdentity(
                endpointID: macKey.publicKey.rawRepresentation.hex
            ),
            identityGeneration: 2,
            platform: .mac
        )
    }

    func sessions() -> CmxIrohOfflinePairingSessions {
        CmxIrohOfflinePairingSessions(
            pairingEnabled: true,
            randomness: FixedRandomness(bytes: Data(repeating: 0x42, count: 32)),
            makeUUID: { UUID(uuidString: "123e4567-e89b-42d3-a456-426614174010")! }
        )
    }

    func invitation(
        from sessions: CmxIrohOfflinePairingSessions
    ) async throws -> CmxIrohOfflinePairingInvitation {
        try await sessions.createInvitation(
            acceptorAttestation: try attestation(for: acceptor),
            keys: keySet,
            acceptor: acceptor,
            now: now
        )
    }

    func initiatorAttestation() throws -> String {
        try attestation(for: initiator)
    }

    private func attestation(for endpoint: CmxIrohEndpointExpectation) throws -> String {
        let claims: [String: Any] = [
            "version": 1,
            "jti": UUID().uuidString.lowercased(),
            "sub": Data(repeating: 7, count: 32).base64URL,
            "bindingId": endpoint.bindingID,
            "deviceId": endpoint.deviceID,
            "endpointId": endpoint.endpointID.endpointID,
            "identityGeneration": endpoint.identityGeneration,
            "platform": endpoint.platform.rawValue,
            "iat": nowSeconds,
            "nbf": nowSeconds - 5,
            "exp": nowSeconds + 3_600,
            "alpn": "cmux/mobile/1",
            "scope": "cmux.offline-pair.same-account",
        ]
        let key = signingKey == .current ? currentKey : previousKey
        let keyID = signingKey == .current ? "current" : "previous"
        let header = try JSONSerialization.data(
            withJSONObject: [
                "alg": "EdDSA",
                "typ": "cmux-endpoint-attestation-v1+jwt",
                "kid": keyID,
            ],
            options: [.sortedKeys]
        ).base64URL
        let body = try JSONSerialization.data(
            withJSONObject: claims,
            options: [.sortedKeys]
        ).base64URL
        let input = "\(header).\(body)"
        let signature = try key.signature(for: Data(input.utf8)).base64URL
        return "\(input).\(signature)"
    }

    private static func verificationKey(
        id: String,
        key: Curve25519.Signing.PrivateKey
    ) -> CmxIrohGrantVerificationKey {
        let prefix = Data([
            0x30, 0x2a, 0x30, 0x05, 0x06, 0x03,
            0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
        ])
        return CmxIrohGrantVerificationKey(
            kid: id,
            alg: "EdDSA",
            spkiDerBase64: (prefix + key.publicKey.rawRepresentation).base64EncodedString()
        )
    }
}

private struct FixedRandomness: CmxIrohRandomByteGenerating {
    let bytes: Data

    func randomBytes(count: Int) throws -> Data {
        guard bytes.count == count else {
            throw CmxIrohOfflinePairingSessionError.randomnessUnavailable
        }
        return bytes
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
