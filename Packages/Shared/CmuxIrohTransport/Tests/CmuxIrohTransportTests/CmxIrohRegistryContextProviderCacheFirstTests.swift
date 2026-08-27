import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

/// Warm-dial cache-first behavior: a dial whose exact target tuple is covered
/// by the verified offline route record is served immediately from that
/// record, with the broker discovery refresh running BEHIND the dial instead
/// of in front of it. Staleness evidence (cmux#10739/#10865) still bypasses
/// every cached source and forces a fresh broker snapshot.
@Suite
struct CmxIrohRegistryContextProviderCacheFirstTests {
    @Test
    func warmDialServesCachedRecordWithoutBlockingBrokerRounds() async throws {
        let fixture = try RegistryFixture()
        let seeded = try await seedOfflinePolicy(fixture: fixture)
        // The broker rejects discovery outright: under dial-blocking
        // discovery this dial could not succeed at all.
        let broker = ConfigurableRegistryBroker(
            discovery: try fixture.discovery(targetHints: []),
            pairGrantResponses: []
        )
        await broker.setDiscoverError(
            CmxIrohTrustBrokerClientError.rejected(statusCode: 503, code: nil)
        )
        let provider = try await makeProvider(
            fixture: fixture,
            broker: broker,
            offlinePolicy: seeded.policy
        )

        let context = try await provider.context(for: fixture.request(hints: []))

        #expect(context.credential.pairGrantToken == seeded.grant.grant)
        #expect(await broker.pairGrantRequestCount() == 0)
    }

    /// The cache-first dial arms one background discovery refresh so the
    /// route cache converges behind the dial instead of staying frozen.
    @Test
    func cacheFirstDialRefreshesDiscoveryBehindTheDial() async throws {
        let fixture = try RegistryFixture()
        let seeded = try await seedOfflinePolicy(fixture: fixture)
        let broker = ConfigurableRegistryBroker(
            discovery: try fixture.discovery(targetHints: [], revision: 3),
            pairGrantResponses: []
        )
        let provider = try await makeProvider(
            fixture: fixture,
            broker: broker,
            offlinePolicy: seeded.policy
        )

        let context = try await provider.context(for: fixture.request(hints: []))
        #expect(context.credential.pairGrantToken == seeded.grant.grant)

        var refreshed = false
        for _ in 0 ..< 50_000 {
            if await broker.discoveryRequestCount() >= 1 {
                refreshed = true
                break
            }
            await Task.yield()
        }
        #expect(refreshed)
        #expect(await broker.pairGrantRequestCount() == 0)
    }

    /// Staleness evidence from a failed dial beats every cached source: the
    /// next dial must fetch a fresh snapshot and rebuild, not redial the
    /// cached corpse route.
    @Test
    func staleEvidenceBypassesCachedRecordAndForcesFreshDiscovery() async throws {
        let fixture = try RegistryFixture()
        let seeded = try await seedOfflinePolicy(fixture: fixture)
        let relay = try CmxIrohPathHint(
            kind: .relayURL,
            value: fixture.relayURL,
            source: .native,
            privacyScope: .publicInternet,
            observedAt: fixture.now,
            expiresAt: fixture.now.addingTimeInterval(60)
        )
        let freshGrant = try fixture.pairGrantResponse(
            issuedAt: fixture.nowSeconds,
            expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
        )
        let broker = ConfigurableRegistryBroker(
            discovery: try fixture.discovery(targetHints: [relay]),
            pairGrantResponses: [freshGrant]
        )
        let provider = try await makeProvider(
            fixture: fixture,
            broker: broker,
            offlinePolicy: seeded.policy
        )
        await provider.noteDialFailure(
            for: try fixture.request(hints: []),
            dialPlan: try testIrohDialPlan(publicPaths: []),
            failure: .timedOut
        )

        let context = try await provider.context(for: fixture.request(hints: []))

        #expect(await broker.discoveryRequestCount() == 1)
        #expect(context.dialPlan.publicPaths == [relay])
    }

    /// A background refresh that proves the cached target vanished (revoked
    /// or replaced server-side) marks the peer stale, so the NEXT dial
    /// rebuilds from fresh discovery instead of reusing the dead record.
    @Test
    func backgroundRefreshEvidenceMarksVanishedTargetStale() async throws {
        let fixture = try RegistryFixture()
        let seeded = try await seedOfflinePolicy(fixture: fixture)
        let broker = ConfigurableRegistryBroker(
            discovery: try fixture.discovery(targetHints: [], includeTarget: false),
            pairGrantResponses: []
        )
        let provider = try await makeProvider(
            fixture: fixture,
            broker: broker,
            offlinePolicy: seeded.policy
        )

        // First dial is served cache-first; its background refresh sees the
        // target dropped from the account.
        _ = try await provider.context(for: fixture.request(hints: []))
        var refreshed = false
        for _ in 0 ..< 50_000 {
            if await broker.discoveryRequestCount() >= 1 {
                refreshed = true
                break
            }
            await Task.yield()
        }
        #expect(refreshed)
        // Let the refresh's staleness verdict land in actor state.
        for _ in 0 ..< 2_000 {
            await Task.yield()
        }

        // The next dial must NOT be served from the cached record: the fresh
        // snapshot (fetched because the peer is stale) has no such target.
        await #expect(throws: CmxIrohRegistryContextError.targetBindingUnavailable) {
            try await provider.context(for: fixture.request(hints: []))
        }
        #expect(await broker.discoveryRequestCount() == 2)
    }

    // MARK: - Support

    private func makeProvider(
        fixture: RegistryFixture,
        broker: any CmxIrohRegistryServing,
        offlinePolicy: CmxIrohClientOfflinePolicyContext?,
        verifiedDiscovery: CmxIrohDiscoveryResponse? = nil
    ) async throws -> CmxIrohRegistryContextProvider {
        CmxIrohRegistryContextProvider(
            supervisor: try await fixture.activeSupervisor(),
            broker: broker,
            localBindingExpectation: try fixture.localExpectation(),
            managedRelayURLs: [fixture.relayURL],
            networkPathSnapshot: {
                CmxIrohNetworkPathSnapshot(
                    generation: 1,
                    activeNetworkProfiles: []
                )
            },
            offlinePolicy: offlinePolicy,
            verifiedDiscovery: verifiedDiscovery,
            now: { fixture.now }
        )
    }

    private func seedOfflinePolicy(
        fixture: RegistryFixture
    ) async throws -> (
        store: TestSecureCredentialStore,
        policy: CmxIrohClientOfflinePolicyContext,
        grant: CmxIrohPairGrantResponse
    ) {
        // The stored target carries a live relay hint so a cache-first dial
        // has a usable plan without a broker round.
        let storedRelayHint = try CmxIrohPathHint(
            kind: .relayURL,
            value: fixture.relayURL,
            source: .native,
            privacyScope: .publicInternet,
            observedAt: fixture.now,
            expiresAt: fixture.now.addingTimeInterval(60)
        )
        let discovery = try fixture.discovery(targetHints: [storedRelayHint])
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
        return (
            store,
            try CmxIrohClientOfflinePolicyContext(
                cache: cache,
                expectation: expectation,
                localBinding: discovery.bindings[0]
            ),
            grant
        )
    }
}
