import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

/// Phone-side warm dial: once a session has been fully admitted, later dials
/// to the same Mac carry no credential and perform zero pair-grant fetches;
/// a refused allowlist admission falls back to the grant path.
@Suite
struct CmxIrohRegistryContextProviderPairedTests {
    private func seededCache(
        fixture: RegistryFixture,
        discovery: CmxIrohDiscoveryResponse,
        store: TestSecureCredentialStore
    ) async throws -> CmxIrohClientOfflinePolicyContext {
        let cache = CmxIrohClientOfflinePolicyCache(secureStore: store)
        let expectation = try fixture.offlineExpectation()
        try await cache.save(
            localBinding: discovery.bindings[0],
            targetBinding: discovery.bindings[1],
            discovery: discovery,
            pairGrant: try fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
            ),
            for: expectation,
            now: fixture.now
        )
        return try CmxIrohClientOfflinePolicyContext(
            cache: cache,
            expectation: expectation,
            localBinding: discovery.bindings[0]
        )
    }

    @Test
    func warmDialAfterAdmissionCarriesNoCredentialAndFetchesNoGrant() async throws {
        let fixture = try RegistryFixture()
        let discovery = try fixture.discovery(targetHints: [])
        let broker = TestIrohRegistryBroker(
            discovery: discovery,
            pairGrantResponses: [
                try fixture.pairGrantResponse(
                    issuedAt: fixture.nowSeconds,
                    expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
                ),
            ]
        )
        let provider = CmxIrohRegistryContextProvider(
            supervisor: try await fixture.activeSupervisor(),
            broker: broker,
            localBindingExpectation: try fixture.localExpectation(),
            managedRelayURLs: [fixture.relayURL],
            activeNetworkProfiles: { [] },
            now: { fixture.now }
        )
        let request = try fixture.request(hints: [])

        // Bootstrap dial fetches the grant.
        let bootstrap = try await provider.context(for: request)
        #expect(bootstrap.credential != nil)
        #expect(await broker.pairGrantRequestCount() == 1)

        // The session was fully admitted: later dials go credential-less
        // with ZERO further pair-grant HTTP calls.
        await provider.noteAdmissionSucceeded(for: request)
        let warm = try await provider.context(for: request)
        #expect(warm.credential == nil)
        #expect(await broker.pairGrantRequestCount() == 1)
    }

    @Test
    func establishedMarkerPersistsAcrossProviderRelaunch() async throws {
        let fixture = try RegistryFixture()
        let discovery = try fixture.discovery(targetHints: [])
        let store = TestSecureCredentialStore()
        let offlinePolicy = try await seededCache(
            fixture: fixture,
            discovery: discovery,
            store: store
        )
        let firstBroker = TestIrohRegistryBroker(
            discovery: discovery,
            pairGrantResponses: []
        )
        let first = CmxIrohRegistryContextProvider(
            supervisor: try await fixture.activeSupervisor(),
            broker: firstBroker,
            localBindingExpectation: try fixture.localExpectation(),
            managedRelayURLs: [fixture.relayURL],
            activeNetworkProfiles: { [] },
            offlinePolicy: offlinePolicy,
            now: { fixture.now }
        )
        await first.noteAdmissionSucceeded(for: try fixture.request(hints: []))

        // A fresh provider (app relaunch) over the same offline cache dials
        // credential-less immediately: zero grant HTTP on the cold warm dial.
        let secondBroker = TestIrohRegistryBroker(
            discovery: discovery,
            pairGrantResponses: []
        )
        let second = CmxIrohRegistryContextProvider(
            supervisor: try await fixture.activeSupervisor(),
            broker: secondBroker,
            localBindingExpectation: try fixture.localExpectation(),
            managedRelayURLs: [fixture.relayURL],
            activeNetworkProfiles: { [] },
            offlinePolicy: try CmxIrohClientOfflinePolicyContext(
                cache: CmxIrohClientOfflinePolicyCache(secureStore: store),
                expectation: try fixture.offlineExpectation(),
                localBinding: discovery.bindings[0]
            ),
            now: { fixture.now }
        )
        let warm = try await second.context(for: try fixture.request(hints: []))
        #expect(warm.credential == nil)
        #expect(await secondBroker.pairGrantRequestCount() == 0)
    }

    @Test
    func refusedAllowlistAdmissionFallsBackToGrantFetch() async throws {
        let fixture = try RegistryFixture()
        let discovery = try fixture.discovery(targetHints: [])
        let broker = TestIrohRegistryBroker(
            discovery: discovery,
            pairGrantResponses: [
                try fixture.pairGrantResponse(
                    issuedAt: fixture.nowSeconds,
                    expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
                ),
            ]
        )
        let provider = CmxIrohRegistryContextProvider(
            supervisor: try await fixture.activeSupervisor(),
            broker: broker,
            localBindingExpectation: try fixture.localExpectation(),
            managedRelayURLs: [fixture.relayURL],
            activeNetworkProfiles: { [] },
            now: { fixture.now }
        )
        let request = try fixture.request(hints: [])
        await provider.noteAdmissionSucceeded(for: request)
        #expect(try await provider.context(for: request).credential == nil)

        // The Mac refused the credential-less dial (allowlist miss): the
        // provider re-arms the bootstrap path and the next context carries a
        // freshly fetched grant.
        await provider.noteAllowlistAdmissionRefused(for: request)
        let fallback = try await provider.context(for: request)
        #expect(fallback.credential?.kind == .pairGrant)
        #expect(await broker.pairGrantRequestCount() == 1)
    }
}
