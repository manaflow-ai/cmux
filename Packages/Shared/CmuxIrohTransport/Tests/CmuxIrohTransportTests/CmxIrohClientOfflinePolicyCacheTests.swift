import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite("Iroh client offline policy cache")
struct CmxIrohClientOfflinePolicyCacheTests {
    @Test("verified target policy round-trips with device-only protection")
    func roundTripsVerifiedPolicy() async throws {
        let fixture = try RegistryFixture()
        let discovery = try fixture.discovery(targetHints: [])
        let grant = try fixture.pairGrantResponse(
            issuedAt: fixture.nowSeconds,
            expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
        )
        let store = TestSecureCredentialStore()
        let cache = CmxIrohClientOfflinePolicyCache(secureStore: store)
        let expectation = try fixture.offlineExpectation()

        try await cache.save(
            localBinding: discovery.bindings[0],
            targetBinding: discovery.bindings[1],
            discovery: discovery,
            pairGrant: grant,
            for: expectation,
            now: fixture.now
        )

        let recreated = CmxIrohClientOfflinePolicyCache(secureStore: store)
        let loaded = try await recreated.load(
            for: fixture.request(hints: []),
            localBinding: discovery.bindings[0],
            expectation: expectation,
            confirmedDiscovery: nil,
            now: fixture.now
        )
        #expect(loaded?.localBinding == discovery.bindings[0])
        #expect(loaded?.targetBinding == discovery.bindings[1])
        #expect(loaded?.pairGrant == grant)
        #expect(loaded?.lanRendezvous == discovery.lanRendezvous)
        #expect(await store.observedAccessibilities() == [.afterFirstUnlockThisDeviceOnly])
    }

    @Test("save rejects grants that do not bind the exact target")
    func saveRejectsSubstitutedTarget() async throws {
        let fixture = try RegistryFixture()
        let discovery = try fixture.discovery(targetHints: [])
        let substituted = try fixture.discovery(
            targetHints: [],
            targetDeviceID: "123e4567-e89b-42d3-a456-426614174099"
        )
        let store = TestSecureCredentialStore()
        let cache = CmxIrohClientOfflinePolicyCache(secureStore: store)

        await #expect(throws: CmxIrohGrantVerifierError.identityMismatch) {
            try await cache.save(
                localBinding: discovery.bindings[0],
                targetBinding: substituted.bindings[1],
                discovery: substituted,
                pairGrant: fixture.pairGrantResponse(
                    issuedAt: fixture.nowSeconds,
                    expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
                ),
                for: fixture.offlineExpectation(),
                now: fixture.now
            )
        }
        #expect(await store.recordCount() == 0)
    }

    @Test("load re-verifies expiry and deletes stale authority")
    func loadDeletesExpiredGrant() async throws {
        let fixture = try RegistryFixture()
        let discovery = try fixture.discovery(targetHints: [])
        let cacheStore = TestSecureCredentialStore()
        let cache = CmxIrohClientOfflinePolicyCache(secureStore: cacheStore)
        let expectation = try fixture.offlineExpectation()
        try await cache.save(
            localBinding: discovery.bindings[0],
            targetBinding: discovery.bindings[1],
            discovery: discovery,
            pairGrant: fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 60
            ),
            for: expectation,
            now: fixture.now
        )

        let loaded = try await cache.load(
            for: fixture.request(hints: []),
            localBinding: discovery.bindings[0],
            expectation: expectation,
            confirmedDiscovery: nil,
            now: fixture.now.addingTimeInterval(61)
        )

        #expect(loaded == nil)
        #expect(await cacheStore.recordCount() == 0)
    }

    @Test("account and local identity changes wipe the active cache")
    func changedScopeDeletesPolicy() async throws {
        let fixture = try RegistryFixture()
        let discovery = try fixture.discovery(targetHints: [])
        let store = TestSecureCredentialStore()
        let cache = CmxIrohClientOfflinePolicyCache(secureStore: store)
        try await cache.save(
            localBinding: discovery.bindings[0],
            targetBinding: discovery.bindings[1],
            discovery: discovery,
            pairGrant: fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 3_600
            ),
            for: fixture.offlineExpectation(),
            now: fixture.now
        )

        #expect(try await cache.loadBootstrap(
            for: fixture.offlineExpectation(accountID: "account-b"),
            confirmedLocalBinding: nil,
            now: fixture.now
        ) == nil)
        #expect(await store.recordCount() == 0)
    }

    @Test("unknown and substituted Mac tuples never receive cached authority")
    func requestMustMatchKnownTargetTuple() async throws {
        let fixture = try RegistryFixture()
        let discovery = try fixture.discovery(targetHints: [])
        let store = TestSecureCredentialStore()
        let cache = CmxIrohClientOfflinePolicyCache(secureStore: store)
        let expectation = try fixture.offlineExpectation()
        try await cache.save(
            localBinding: discovery.bindings[0],
            targetBinding: discovery.bindings[1],
            discovery: discovery,
            pairGrant: fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 3_600
            ),
            for: expectation,
            now: fixture.now
        )

        let unknown = try fixture.request(
            hints: [],
            expectedPeerDeviceID: "123e4567-e89b-42d3-a456-426614174099"
        )
        #expect(try await cache.load(
            for: unknown,
            localBinding: discovery.bindings[0],
            expectation: expectation,
            confirmedDiscovery: nil,
            now: fixture.now
        ) == nil)
        #expect(await store.recordCount() == 1)
    }

    @Test("corrupt records and changed relay fleets are deleted")
    func corruptAndWrongFleetDeletePolicy() async throws {
        let fixture = try RegistryFixture()
        let discovery = try fixture.discovery(targetHints: [])
        let store = TestSecureCredentialStore()
        let cache = CmxIrohClientOfflinePolicyCache(secureStore: store)
        try await cache.save(
            localBinding: discovery.bindings[0],
            targetBinding: discovery.bindings[1],
            discovery: discovery,
            pairGrant: fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 3_600
            ),
            for: fixture.offlineExpectation(),
            now: fixture.now
        )
        let account = try #require(await store.lastDeletedOrWrittenAccount())
        await store.seed(Data("not-json".utf8), account: account)
        #expect(try await cache.loadBootstrap(
            for: fixture.offlineExpectation(),
            confirmedLocalBinding: nil,
            now: fixture.now
        ) == nil)
        #expect(await store.recordCount() == 0)

        try await cache.save(
            localBinding: discovery.bindings[0],
            targetBinding: discovery.bindings[1],
            discovery: discovery,
            pairGrant: fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 3_600
            ),
            for: fixture.offlineExpectation(),
            now: fixture.now
        )
        #expect(try await cache.loadBootstrap(
            for: fixture.offlineExpectation(
                managedRelayURLs: ["https://other.example.com/"]
            ),
            confirmedLocalBinding: nil,
            now: fixture.now
        ) == nil)
        #expect(await store.recordCount() == 0)
    }

    @Test("changed local identity and confirmed target revocation delete authority")
    func localIdentityAndConfirmedRevocationDeletePolicy() async throws {
        let fixture = try RegistryFixture()
        let discovery = try fixture.discovery(targetHints: [])
        let store = TestSecureCredentialStore()
        let cache = CmxIrohClientOfflinePolicyCache(secureStore: store)
        let grant = try fixture.pairGrantResponse(
            issuedAt: fixture.nowSeconds,
            expiresAt: fixture.nowSeconds + 3_600
        )
        try await cache.save(
            localBinding: discovery.bindings[0],
            targetBinding: discovery.bindings[1],
            discovery: discovery,
            pairGrant: grant,
            for: fixture.offlineExpectation(),
            now: fixture.now
        )
        let changedLocal = try CmxIrohLocalBindingExpectation(
            deviceID: fixture.initiator.deviceID,
            appInstanceID: discovery.bindings[0].appInstanceID,
            tag: fixture.initiator.tag,
            platform: .ios,
            endpointID: fixture.initiator.endpointID,
            identityGeneration: fixture.initiator.identityGeneration + 1,
            pairingEnabled: false,
            capabilities: discovery.bindings[0].capabilities
        )
        #expect(try await cache.loadBootstrap(
            for: fixture.offlineExpectation(localExpectation: changedLocal),
            confirmedLocalBinding: nil,
            now: fixture.now
        ) == nil)
        #expect(await store.recordCount() == 0)

        try await cache.save(
            localBinding: discovery.bindings[0],
            targetBinding: discovery.bindings[1],
            discovery: discovery,
            pairGrant: grant,
            for: fixture.offlineExpectation(),
            now: fixture.now
        )
        let revoked = try fixture.discovery(targetHints: [], includeTarget: false)
        #expect(try await cache.load(
            for: fixture.request(hints: []),
            localBinding: discovery.bindings[0],
            expectation: fixture.offlineExpectation(),
            confirmedDiscovery: revoked,
            now: fixture.now
        ) == nil)
        #expect(await store.recordCount() == 0)
    }
}
