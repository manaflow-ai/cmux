import CMUXMobileCore
import CryptoKit
import Foundation
import Testing
@testable import CmuxPeerTransport

/// Offline grant cache semantics: consulted only after broker connectivity
/// failure, scoped to account + app instance + local identity/generation +
/// relay fleet + verification keys + grant expiry, deleted on sign-out.
@Suite
struct PeerOfflineGrantCacheTests {
    @Test
    func savedGrantIsServedOnlyAfterAConnectivityFailure() async throws {
        let fixture = try CacheFixture()
        try await fixture.saveDefaultGrant()

        let hit = try await fixture.load(afterFailure: .connectivity)
        #expect(hit?.targetBinding == fixture.targetBinding)
        #expect(hit?.localBinding == fixture.localBinding)
        #expect(hit?.pairGrant == fixture.pairGrant)
        #expect(hit?.grantVerificationKeys == fixture.grant.keySet)

        // Auth, denial, rate-limit, and protocol failures fail closed WITHOUT
        // even reading storage, and without deleting the record.
        let readsBefore = await fixture.store.readCount
        for failure: PeerBrokerError in [
            .unauthorized,
            .denied(statusCode: 403, code: "forbidden"),
            .denied(statusCode: 500, code: nil),
            .serverRateLimited(retryAfter: .seconds(60)),
            .protocolError,
        ] {
            let miss = try await fixture.load(afterFailure: failure)
            #expect(miss == nil)
        }
        #expect(await fixture.store.readCount == readsBefore)
        #expect(await fixture.store.contents().isEmpty == false)

        // The record is still intact for the next real connectivity failure.
        let secondHit = try await fixture.load(afterFailure: .connectivity)
        #expect(secondHit?.targetBinding == fixture.targetBinding)
    }

    @Test
    func recordsWrittenByThePreviousTransportAreServed() async throws {
        let fixture = try CacheFixture()
        // Byte-exact legacy record JSON (field names as the old engine wrote
        // them) installed directly into the keychain stub.
        let legacyJSON = """
        {
          "version": 1,
          "scopeDigest": "\(fixture.scopeDigest)",
          "localBinding": \(fixture.localBindingJSON),
          "relayFleet": ["\(CacheFixture.relayURL)"],
          "grantVerificationKeys": \(fixture.keySetJSON),
          "lanRendezvous": {"generation": 1, "key": "\(CacheFixture.lanKey)"},
          "targets": [{
            "binding": \(fixture.targetBindingJSON),
            "pairGrant": {
              "grant": "\(fixture.pairGrant.grant)",
              "expires_at": "\(fixture.pairGrant.expiresAt)"
            }
          }]
        }
        """
        await fixture.store.install(
            Data(legacyJSON.utf8),
            account: "active-client-policies"
        )

        let hit = try await fixture.load(afterFailure: .connectivity)

        #expect(hit?.targetBinding == fixture.targetBinding)
        #expect(hit?.pairGrant == fixture.pairGrant)
    }

    @Test
    func accountScopeMismatchRejectsTheRecord() async throws {
        let fixture = try CacheFixture()
        try await fixture.saveDefaultGrant()

        let otherAccount = try PeerOfflineGrantExpectation(
            accountID: "another-account",
            localBindingExpectation: fixture.expectation.localBindingExpectation,
            managedRelayURLs: fixture.expectation.managedRelayURLs
        )
        let miss = try await fixture.load(
            afterFailure: .connectivity,
            expectation: otherAccount
        )
        #expect(miss == nil)
        // An out-of-scope record is deleted, not resurrected later.
        #expect(await fixture.store.contents().isEmpty)
    }

    @Test
    func relayFleetMismatchRejectsTheRecord() async throws {
        let fixture = try CacheFixture()
        try await fixture.saveDefaultGrant()

        let otherFleet = try PeerOfflineGrantExpectation(
            accountID: CacheFixture.accountID,
            localBindingExpectation: fixture.expectation.localBindingExpectation,
            managedRelayURLs: ["https://other.relay.example/"]
        )
        let miss = try await fixture.load(
            afterFailure: .connectivity,
            expectation: otherFleet
        )
        #expect(miss == nil)
    }

    @Test
    func localIdentityGenerationMismatchRejectsTheRecord() async throws {
        let fixture = try CacheFixture()
        try await fixture.saveDefaultGrant()

        let rotatedLocal = try PeerLocalBindingExpectation(
            deviceID: fixture.localBinding.deviceID,
            appInstanceID: fixture.localBinding.appInstanceID,
            tag: fixture.localBinding.tag,
            platform: .ios,
            endpointID: fixture.localBinding.endpointID,
            identityGeneration: fixture.localBinding.identityGeneration + 1,
            pairingEnabled: fixture.localBinding.pairingEnabled,
            capabilities: fixture.localBinding.capabilities
        )
        let rotatedExpectation = try PeerOfflineGrantExpectation(
            accountID: CacheFixture.accountID,
            localBindingExpectation: rotatedLocal,
            managedRelayURLs: fixture.expectation.managedRelayURLs
        )
        let miss = try await fixture.load(
            afterFailure: .connectivity,
            expectation: rotatedExpectation
        )
        #expect(miss == nil)
    }

    @Test
    func wrongTargetTupleMissesWithoutDeletingTheRecord() async throws {
        let fixture = try CacheFixture()
        try await fixture.saveDefaultGrant()

        let missByDevice = try await fixture.load(
            afterFailure: .connectivity,
            targetDeviceID: "999e4567-e89b-42d3-a456-426614174999"
        )
        #expect(missByDevice == nil)
        let missByEndpoint = try await fixture.load(
            afterFailure: .connectivity,
            targetEndpointID: try CmxIrohPeerIdentity(
                endpointID: String(repeating: "f", count: 64)
            )
        )
        #expect(missByEndpoint == nil)
        #expect(await fixture.store.contents().isEmpty == false)
    }

    @Test
    func expiredGrantIsPrunedOnLoad() async throws {
        let fixture = try CacheFixture()
        try await fixture.saveDefaultGrant()

        let afterExpiry = fixture.grant.now.addingTimeInterval(7_200)
        let miss = try await fixture.load(afterFailure: .connectivity, now: afterExpiry)
        #expect(miss == nil)
        // The empty record was deleted rather than kept as a husk.
        #expect(await fixture.store.contents().isEmpty)
    }

    @Test
    func verificationKeyRotationInvalidatesStoredGrants() async throws {
        let fixture = try CacheFixture()
        try await fixture.saveDefaultGrant()

        // Replace the stored key set with a rotated key: the stored grant no
        // longer verifies, so the target is dropped.
        let contents = await fixture.store.contents()
        let data = try #require(contents["active-client-policies"])
        var record = try JSONDecoder().decode(PeerStoredGrantRecord.self, from: data)
        let rotated = GrantFixture.spkiPrefix
            + (try CryptoStub.publicKey(seed: 5))
        record = PeerStoredGrantRecord(
            version: record.version,
            scopeDigest: record.scopeDigest,
            localBinding: record.localBinding,
            relayFleet: record.relayFleet,
            grantVerificationKeys: PeerGrantVerificationKeySet(
                version: 1,
                currentKeyID: "current",
                keys: [
                    PeerGrantVerificationKey(
                        kid: "current",
                        alg: "EdDSA",
                        spkiDerBase64: rotated.base64EncodedString()
                    ),
                ]
            ),
            lanRendezvous: record.lanRendezvous,
            targets: record.targets
        )
        await fixture.store.install(
            try JSONEncoder().encode(record),
            account: "active-client-policies"
        )

        let miss = try await fixture.load(afterFailure: .connectivity)
        #expect(miss == nil)
    }

    @Test
    func saveRejectsAGrantThatDoesNotVerifyForTheExactPair() async throws {
        let fixture = try CacheFixture()
        // A grant for a DIFFERENT acceptor tuple must not enter the cache.
        let foreignGrant = try fixture.grant.pairGrant(
            initiator: PeerGrantPeer(binding: fixture.localBinding),
            acceptor: PeerGrantPeer(
                bindingID: "123e4567-e89b-42d3-a456-426614174777",
                deviceID: fixture.targetBinding.deviceID,
                tag: fixture.targetBinding.tag,
                platform: .mac,
                endpointID: fixture.targetBinding.endpointID,
                identityGeneration: fixture.targetBinding.identityGeneration
            ),
            expiresAt: fixture.grant.nowSeconds + 3_600
        )
        await #expect(throws: PeerGrantVerifierError.identityMismatch) {
            try await fixture.cache.save(
                localBinding: fixture.localBinding,
                targetBinding: fixture.targetBinding,
                discovery: fixture.discovery,
                pairGrant: PeerPairGrantResponse(
                    grant: foreignGrant,
                    expiresAt: fixture.pairGrant.expiresAt
                ),
                for: fixture.expectation,
                now: fixture.grant.now
            )
        }
        #expect(await fixture.store.contents().isEmpty)
    }

    @Test
    func deactivationDeletesEveryCachedGrant() async throws {
        let fixture = try CacheFixture()
        try await fixture.saveDefaultGrant()
        #expect(await fixture.store.contents().isEmpty == false)

        try await fixture.cache.deactivate()

        #expect(await fixture.store.contents().isEmpty)
        #expect(await fixture.store.deleteAllCount == 1)
        let miss = try await fixture.load(afterFailure: .connectivity)
        #expect(miss == nil)
    }

    @Test
    func unavailableStorageFailsClosedWithoutDeletingAnything() async throws {
        let fixture = try CacheFixture()
        try await fixture.saveDefaultGrant()

        await fixture.store.setUnavailable(status: -25308)
        let miss = try await fixture.load(afterFailure: .connectivity)
        #expect(miss == nil)

        await fixture.store.setUnavailable(status: nil)
        let recovered = try await fixture.load(afterFailure: .connectivity)
        #expect(recovered?.targetBinding == fixture.targetBinding)
    }
}

private enum CryptoStub {
    static func publicKey(seed: UInt8) throws -> Data {
        let key = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: seed, count: 32)
        )
        return key.publicKey.rawRepresentation
    }
}

/// Composes the grant fixture with decoded bindings, a discovery snapshot,
/// and a cache over an in-memory keychain stub.
private struct CacheFixture {
    static let accountID = "user-account"
    static let relayURL = "https://usc1.relay.cmux.dev/"
    static let lanKey = String(repeating: "A", count: 43)

    let grant: GrantFixture
    let store = MemoryBlobStore()
    let cache: PeerOfflineGrantCache
    let localBinding: PeerBrokerBinding
    let targetBinding: PeerBrokerBinding
    let discovery: PeerBrokerDiscoverySnapshot
    let pairGrant: PeerPairGrantResponse
    let expectation: PeerOfflineGrantExpectation
    let localBindingJSON: String
    let targetBindingJSON: String
    let keySetJSON: String
    let scopeDigest: String

    init() throws {
        grant = try GrantFixture()
        cache = PeerOfflineGrantCache(secureStore: store)
        keySetJSON = String(
            data: try JSONEncoder().encode(grant.keySet),
            encoding: .utf8
        )!
        localBindingJSON = Self.bindingJSON(
            peer: grant.initiator,
            appInstanceID: "223e4567-e89b-42d3-a456-426614174001",
            pairingEnabled: false
        )
        targetBindingJSON = Self.bindingJSON(
            peer: grant.acceptor,
            appInstanceID: "223e4567-e89b-42d3-a456-426614174002",
            pairingEnabled: true
        )
        let decoder = JSONDecoder()
        localBinding = try decoder.decode(
            PeerBrokerBinding.self,
            from: Data(localBindingJSON.utf8)
        )
        targetBinding = try decoder.decode(
            PeerBrokerBinding.self,
            from: Data(targetBindingJSON.utf8)
        )
        let discoveryJSON = """
        {
          "route_contract_version": 1,
          "revision": 12,
          "bindings": [\(localBindingJSON), \(targetBindingJSON)],
          "relay_fleet": ["\(Self.relayURL)"],
          "lan_rendezvous": {"generation": 1, "key": "\(Self.lanKey)"},
          "grant_verification_keys": \(keySetJSON)
        }
        """
        discovery = try decoder.decode(
            PeerBrokerDiscoverySnapshot.self,
            from: Data(discoveryJSON.utf8)
        )
        let expiresAt = grant.nowSeconds + 3_600
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        pairGrant = PeerPairGrantResponse(
            grant: try grant.pairGrant(expiresAt: expiresAt),
            expiresAt: formatter.string(
                from: Date(timeIntervalSince1970: TimeInterval(expiresAt))
            )
        )
        expectation = try PeerOfflineGrantExpectation(
            accountID: Self.accountID,
            localBindingExpectation: PeerLocalBindingExpectation(
                deviceID: localBinding.deviceID,
                appInstanceID: localBinding.appInstanceID,
                tag: localBinding.tag,
                platform: .ios,
                endpointID: localBinding.endpointID,
                identityGeneration: localBinding.identityGeneration,
                pairingEnabled: localBinding.pairingEnabled,
                capabilities: localBinding.capabilities
            ),
            managedRelayURLs: [Self.relayURL]
        )
        let transcript = Data(
            "cmux/iroh/offline-client-policy-scope/v2\0\(Self.accountID)\0legacy\0\(localBinding.appInstanceID)".utf8
        )
        scopeDigest = SHA256.hash(data: transcript)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func saveDefaultGrant() async throws {
        try await cache.save(
            localBinding: localBinding,
            targetBinding: targetBinding,
            discovery: discovery,
            pairGrant: pairGrant,
            for: expectation,
            now: grant.now
        )
    }

    func load(
        afterFailure failure: PeerBrokerError,
        targetDeviceID: String? = nil,
        targetEndpointID: CmxIrohPeerIdentity? = nil,
        expectation overrideExpectation: PeerOfflineGrantExpectation? = nil,
        now: Date? = nil
    ) async throws -> PeerCachedGrantAuthority? {
        try await cache.load(
            afterBrokerFailure: failure,
            targetDeviceID: targetDeviceID ?? targetBinding.deviceID,
            targetEndpointID: targetEndpointID ?? targetBinding.endpointID,
            expectation: overrideExpectation ?? expectation,
            confirmedLocalBinding: localBinding,
            now: now ?? grant.now
        )
    }

    private static func bindingJSON(
        peer: PeerGrantPeer,
        appInstanceID: String,
        pairingEnabled: Bool
    ) -> String {
        """
        {
          "binding_id": "\(peer.bindingID)",
          "device_id": "\(peer.deviceID)",
          "app_instance_id": "\(appInstanceID)",
          "tag": "\(peer.tag)",
          "platform": "\(peer.platform.rawValue)",
          "endpoint_id": "\(peer.endpointID.endpointID)",
          "identity_generation": \(peer.identityGeneration),
          "pairing_enabled": \(pairingEnabled),
          "capabilities": ["control"],
          "path_hints": [],
          "last_seen_at": "2026-07-10T00:00:00.000Z"
        }
        """
    }
}
