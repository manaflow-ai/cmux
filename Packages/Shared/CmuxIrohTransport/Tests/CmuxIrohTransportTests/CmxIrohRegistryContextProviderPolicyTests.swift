import CryptoKit
import CMUXMobileCore
import Foundation
import Testing

@testable import CmuxIrohTransport

extension CmxIrohRegistryContextProviderTests {
    @Test
    func discoveryMustPublishTheExactConfiguredRelayFleet() async throws {
        let fixture = try RegistryFixture()
        let broker = TestIrohRegistryBroker(
            discovery: try fixture.discovery(
                targetHints: [],
                relayFleet: [fixture.relayURL, "https://unexpected.example.com/"]
            ),
            pairGrantResponses: []
        )
        let provider = CmxIrohRegistryContextProvider(
            supervisor: try await fixture.activeSupervisor(),
            broker: broker,
            localBindingExpectation: try fixture.localExpectation(),
            managedRelayURLs: [fixture.relayURL],
            activeNetworkProfiles: { [] },
            now: { fixture.now }
        )

        await #expect(throws: CmxIrohRegistryContextError.relayFleetMismatch) {
            try await provider.context(for: fixture.request(hints: []))
        }
        #expect(await broker.pairGrantRequestCount() == 0)
    }

    @Test
    func routeEndpointCannotSubstituteAnotherDeviceBinding() async throws {
        let fixture = try RegistryFixture()
        let broker = TestIrohRegistryBroker(
            discovery: try fixture.discovery(targetHints: []),
            pairGrantResponses: []
        )
        let provider = CmxIrohRegistryContextProvider(
            supervisor: try await fixture.activeSupervisor(),
            broker: broker,
            localBindingExpectation: try fixture.localExpectation(),
            managedRelayURLs: [fixture.relayURL],
            activeNetworkProfiles: { [] },
            now: { fixture.now }
        )
        let substitutedRequest = try fixture.request(
            hints: [],
            expectedPeerDeviceID: "123e4567-e89b-42d3-a456-426614174099"
        )

        await #expect(throws: CmxIrohRegistryContextError.targetDeviceMismatch) {
            try await provider.context(for: substitutedRequest)
        }
        #expect(await broker.pairGrantRequestCount() == 0)
    }

    @Test
    func legacyUppercaseUUIDMatchesCanonicalBrokerDeviceID() async throws {
        let fixture = try RegistryFixture()
        let response = try fixture.pairGrantResponse(
            issuedAt: fixture.nowSeconds,
            expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
        )
        let broker = TestIrohRegistryBroker(
            discovery: try fixture.discovery(targetHints: []),
            pairGrantResponses: [response]
        )
        let provider = CmxIrohRegistryContextProvider(
            supervisor: try await fixture.activeSupervisor(),
            broker: broker,
            localBindingExpectation: try fixture.localExpectation(),
            managedRelayURLs: [fixture.relayURL],
            activeNetworkProfiles: { [] },
            now: { fixture.now }
        )

        let context = try await provider.context(for: fixture.request(
            hints: [],
            expectedPeerDeviceID: fixture.acceptor.deviceID.uppercased()
        ))

        #expect(context.credential.pairGrantToken == response.grant)
        #expect(await broker.pairGrantRequestCount() == 1)
    }

    @Test
    func localEndpointIDCannotSubstituteAnotherAppInstanceBinding() async throws {
        let fixture = try RegistryFixture()
        let broker = TestIrohRegistryBroker(
            discovery: try fixture.discovery(
                targetHints: [],
                localAppInstanceID: "123e4567-e89b-42d3-a456-426614174099"
            ),
            pairGrantResponses: [try fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
            )]
        )
        let provider = CmxIrohRegistryContextProvider(
            supervisor: try await fixture.activeSupervisor(),
            broker: broker,
            localBindingExpectation: try fixture.localExpectation(),
            managedRelayURLs: [fixture.relayURL],
            activeNetworkProfiles: { [] },
            now: { fixture.now }
        )

        await #expect(throws: CmxIrohRegistryContextError.localBindingUnavailable) {
            try await provider.context(for: fixture.request(hints: []))
        }
        #expect(await broker.pairGrantRequestCount() == 0)
    }

    @Test
    func discoveryConnectivityUsesOnlyAReverifiedOfflinePolicy() async throws {
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
        let broker = TestIrohRegistryBroker(
            discovery: discovery,
            pairGrantResponses: [],
            discoveryError: CmxIrohTrustBrokerClientError.connectivity
        )
        let provider = CmxIrohRegistryContextProvider(
            supervisor: try await fixture.activeSupervisor(),
            broker: broker,
            localBindingExpectation: try fixture.localExpectation(),
            managedRelayURLs: [fixture.relayURL],
            activeNetworkProfiles: { [] },
            offlinePolicy: try CmxIrohClientOfflinePolicyContext(
                cache: cache,
                expectation: expectation,
                localBinding: discovery.bindings[0]
            ),
            now: { fixture.now }
        )

        let context = try await provider.context(for: fixture.request(hints: []))

        #expect(context.credential.pairGrantToken == grant.grant)
        #expect(await store.readCount() > 0)
    }

    @Test
    func grantConnectivityUsesCacheOnlyForFreshlyConfirmedTuples() async throws {
        let fixture = try RegistryFixture()
        let discovery = try fixture.discovery(targetHints: [])
        let grant = try fixture.pairGrantResponse(
            issuedAt: fixture.nowSeconds,
            expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
        )
        let cache = CmxIrohClientOfflinePolicyCache(
            secureStore: TestSecureCredentialStore()
        )
        let expectation = try fixture.offlineExpectation()
        try await cache.save(
            localBinding: discovery.bindings[0],
            targetBinding: discovery.bindings[1],
            discovery: discovery,
            pairGrant: grant,
            for: expectation,
            now: fixture.now
        )
        let broker = TestIrohRegistryBroker(
            discovery: discovery,
            pairGrantResponses: [],
            pairGrantError: CmxIrohTrustBrokerClientError.connectivity
        )
        let provider = CmxIrohRegistryContextProvider(
            supervisor: try await fixture.activeSupervisor(),
            broker: broker,
            localBindingExpectation: try fixture.localExpectation(),
            managedRelayURLs: [fixture.relayURL],
            activeNetworkProfiles: { [] },
            offlinePolicy: try CmxIrohClientOfflinePolicyContext(
                cache: cache,
                expectation: expectation,
                localBinding: discovery.bindings[0]
            ),
            now: { fixture.now }
        )

        let context = try await provider.context(for: fixture.request(hints: []))

        #expect(context.credential.pairGrantToken == grant.grant)
        #expect(await broker.pairGrantRequestCount() == 1)
    }

    @Test
    func authenticatedBrokerFailuresNeverConsultOfflinePolicy() async throws {
        let fixture = try RegistryFixture()
        let discovery = try fixture.discovery(targetHints: [])
        let store = TestSecureCredentialStore()
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
        let readsBeforeDial = await store.readCount()
        let broker = TestIrohRegistryBroker(
            discovery: discovery,
            pairGrantResponses: [],
            discoveryError: CmxIrohTrustBrokerClientError.rejected(
                statusCode: 401,
                code: "unauthorized"
            )
        )
        let provider = CmxIrohRegistryContextProvider(
            supervisor: try await fixture.activeSupervisor(),
            broker: broker,
            localBindingExpectation: try fixture.localExpectation(),
            managedRelayURLs: [fixture.relayURL],
            activeNetworkProfiles: { [] },
            offlinePolicy: try CmxIrohClientOfflinePolicyContext(
                cache: cache,
                expectation: expectation,
                localBinding: discovery.bindings[0]
            ),
            now: { fixture.now }
        )

        await #expect(throws: CmxIrohTrustBrokerClientError.rejected(
            statusCode: 401,
            code: "unauthorized"
        )) {
            try await provider.context(for: fixture.request(hints: []))
        }
        #expect(await store.readCount() == readsBeforeDial)
    }

    @Test
    func tlsAndDecodeFailuresNeverConsultOfflinePolicy() async throws {
        let fixture = try RegistryFixture()
        let discovery = try fixture.discovery(targetHints: [])
        let store = TestSecureCredentialStore()
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
        for error in [
            TestRegistryBrokerFailure.tls,
            TestRegistryBrokerFailure.decode,
        ] {
            let readsBeforeDial = await store.readCount()
            let broker = TestIrohRegistryBroker(
                discovery: discovery,
                pairGrantResponses: [],
                discoveryError: error.error
            )
            let provider = CmxIrohRegistryContextProvider(
                supervisor: try await fixture.activeSupervisor(),
                broker: broker,
                localBindingExpectation: try fixture.localExpectation(),
                managedRelayURLs: [fixture.relayURL],
                activeNetworkProfiles: { [] },
                offlinePolicy: try CmxIrohClientOfflinePolicyContext(
                    cache: cache,
                    expectation: expectation,
                    localBinding: discovery.bindings[0]
                ),
                now: { fixture.now }
            )

            do {
                _ = try await provider.context(for: fixture.request(hints: []))
                Issue.record("Expected \(error) to fail closed")
            } catch {
                #expect(await store.readCount() == readsBeforeDial)
            }
        }
    }

    @Test
    func pairGrantRateLimitSuppressesBrokerRequestsUntilRetryDeadline() async throws {
        let fixture = try RegistryFixture()
        let clock = TestRegistryClock(fixture.now)
        let rateLimit = CmxIrohTrustBrokerClientError.rateLimited(
            code: "pair_grant_hour_quota",
            retryAfterSeconds: 120
        )
        let broker = TestIrohRegistryBroker(
            discovery: try fixture.discovery(targetHints: []),
            pairGrantResponses: [],
            pairGrantError: rateLimit
        )
        let provider = CmxIrohRegistryContextProvider(
            supervisor: try await fixture.activeSupervisor(),
            broker: broker,
            localBindingExpectation: try fixture.localExpectation(),
            managedRelayURLs: [fixture.relayURL],
            activeNetworkProfiles: { [] },
            now: { clock.value() }
        )
        let request = try fixture.request(hints: [])

        await #expect(throws: rateLimit) {
            try await provider.context(for: request)
        }
        await #expect(throws: rateLimit) {
            try await provider.context(for: request)
        }
        #expect(await broker.pairGrantRequestCount() == 1)

        clock.set(fixture.now.addingTimeInterval(121))
        await #expect(throws: rateLimit) {
            try await provider.context(for: request)
        }
        #expect(await broker.pairGrantRequestCount() == 2)
    }
}
