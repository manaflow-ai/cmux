import CMUXMobileCore
@preconcurrency import CryptoKit
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

    @Test
    func admissionControllerVerifiesOfflineProofBeforeBrokerTraffic() async throws {
        let fixture = try OfflineFixture()
        let sessions = fixture.sessions()
        let broker = OfflineAdmissionBroker(
            responses: [.success(try fixture.discovery())]
        )
        let controller = fixture.controller(sessions: sessions, broker: broker)
        let invitation = try await fixture.invitation(from: sessions)
        let attestation = try fixture.initiatorAttestation()
        let wrongProof = try CmxIrohAdmissionCredential.offlinePairing(
            endpointAttestation: attestation,
            invitationID: CmxIrohResourceID(invitation.sessionID),
            proof: Data(repeating: 0xff, count: 32)
        )

        #expect(
            await controller.authorize(
                credential: wrongProof,
                authenticatedPeerID: fixture.initiator.endpointID
            ) == .denied(code: 1)
        )
        #expect(await broker.callCount() == 0)

        let correct = try invitation.admissionCredential(
            initiatorAttestation: attestation
        )
        #expect(
            await controller.authorize(
                credential: correct,
                authenticatedPeerID: fixture.acceptor.endpointID
            ) == .denied(code: 1)
        )
        #expect(await broker.callCount() == 0)
    }

    @Test
    func admissionControllerReturnsMonitoredOfflineLease() async throws {
        let fixture = try OfflineFixture()
        let sessions = fixture.sessions()
        let broker = OfflineAdmissionBroker(
            responses: [.success(try fixture.discovery())]
        )
        let controller = fixture.controller(sessions: sessions, broker: broker)
        let invitation = try await fixture.invitation(from: sessions)
        let credential = try invitation.admissionCredential(
            initiatorAttestation: try fixture.initiatorAttestation()
        )

        let authorization = await controller.authorize(
            credential: credential,
            authenticatedPeerID: fixture.initiator.endpointID
        )

        guard case let .accepted(peer, onlineLease: lease?) = authorization else {
            Issue.record("Expected monitored offline authorization")
            return
        }
        #expect(peer.endpointID == fixture.initiator.endpointID)
        #expect(lease.expiresAt == fixture.now.addingTimeInterval(3_600))
        #expect(await broker.callCount() == 1)
    }

    @Test
    func onlineMissingBindingDeniesAfterConsumingOfflineProof() async throws {
        let fixture = try OfflineFixture()
        let sessions = fixture.sessions()
        let broker = OfflineAdmissionBroker(
            responses: [.success(try fixture.discovery(includeInitiator: false))]
        )
        let controller = fixture.controller(sessions: sessions, broker: broker)
        let invitation = try await fixture.invitation(from: sessions)
        let credential = try invitation.admissionCredential(
            initiatorAttestation: try fixture.initiatorAttestation()
        )

        #expect(
            await controller.authorize(
                credential: credential,
                authenticatedPeerID: fixture.initiator.endpointID
            ) == .denied(code: 1)
        )
        #expect(
            await controller.authorize(
                credential: credential,
                authenticatedPeerID: fixture.initiator.endpointID
            ) == .denied(code: 1)
        )
        #expect(await broker.callCount() == 1)
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
    let relayURL = "https://use1-1.relay.lawrence.cmux.iroh.link/"

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

    func controller(
        sessions: CmxIrohOfflinePairingSessions,
        broker: OfflineAdmissionBroker
    ) -> CmxIrohAdmissionController {
        let acceptor = grantPeer(for: acceptor, tag: "mac")
        let registry = CmxIrohOnlineAdmissionRegistry(
            broker: broker,
            keys: keySet,
            acceptor: acceptor,
            managedRelayURLs: [relayURL],
            clock: OfflineAdmissionFixedClock(now: now)
        )
        return CmxIrohAdmissionController(
            acceptor: acceptor,
            pairingEnabled: true,
            offlineSessions: sessions,
            onlineRegistry: registry,
            now: { now }
        )
    }

    func discovery(includeInitiator: Bool = true) throws -> CmxIrohDiscoveryResponse {
        var bindings: [[String: Any]] = []
        if includeInitiator {
            bindings.append(bindingObject(endpoint: initiator, tag: "ios", pairable: true))
        }
        bindings.append(bindingObject(endpoint: acceptor, tag: "mac", pairable: true))
        return try JSONDecoder().decode(
            CmxIrohDiscoveryResponse.self,
            from: JSONSerialization.data(withJSONObject: [
                "route_contract_version": 1,
                "bindings": bindings,
                "relay_fleet": [relayURL],
                "lan_rendezvous": [
                    "generation": 1,
                    "key": Data(repeating: 4, count: 32).base64URL,
                ],
                "grant_verification_keys": try JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(keySet)
                ),
            ])
        )
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

    private func grantPeer(
        for endpoint: CmxIrohEndpointExpectation,
        tag: String
    ) -> CmxIrohGrantPeer {
        CmxIrohGrantPeer(
            bindingID: endpoint.bindingID,
            deviceID: endpoint.deviceID,
            tag: tag,
            platform: endpoint.platform,
            endpointID: endpoint.endpointID,
            identityGeneration: endpoint.identityGeneration
        )
    }

    private func bindingObject(
        endpoint: CmxIrohEndpointExpectation,
        tag: String,
        pairable: Bool
    ) -> [String: Any] {
        [
            "binding_id": endpoint.bindingID,
            "device_id": endpoint.deviceID,
            "app_instance_id": endpoint.platform == .ios
                ? "123e4567-e89b-42d3-a456-426614174030"
                : "123e4567-e89b-42d3-a456-426614174031",
            "tag": tag,
            "platform": endpoint.platform.rawValue,
            "display_name": NSNull(),
            "endpoint_id": endpoint.endpointID.endpointID,
            "identity_generation": endpoint.identityGeneration,
            "pairing_enabled": pairable,
            "capabilities": ["multistream-v1"],
            "path_hints": [],
            "last_seen_at": "2027-01-15T08:00:00Z",
        ]
    }
}

private actor OfflineAdmissionBroker: CmxIrohDiscoveryServing {
    private var responses: [Result<CmxIrohDiscoveryResponse, CmxIrohTrustBrokerClientError>]
    private var calls = 0

    init(responses: [Result<CmxIrohDiscoveryResponse, CmxIrohTrustBrokerClientError>]) {
        self.responses = responses
    }

    func discover() throws -> CmxIrohDiscoveryResponse {
        calls += 1
        guard !responses.isEmpty else { throw CmxIrohTrustBrokerClientError.invalidResponse }
        return try responses.removeFirst().get()
    }

    func callCount() -> Int { calls }
}

private struct OfflineAdmissionFixedClock: CmxIrohRelayClock {
    let current: Date

    init(now: Date) { current = now }
    func now() -> Date { current }
    func sleep(until _: Date) async throws {
        try await Task<Never, Never>.sleep(for: .seconds(24 * 60 * 60))
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
