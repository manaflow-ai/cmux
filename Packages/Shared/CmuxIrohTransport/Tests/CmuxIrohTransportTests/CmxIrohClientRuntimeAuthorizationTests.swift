import CMUXMobileCore
import CryptoKit
import Testing
@testable import CmuxIrohTransport

extension CmxIrohClientRuntimeTests {
    @Test
    func firstDialReusesStartupDiscoveryWhenBrokerRateLimitsDuplicateLookup() async throws {
        let fixture = try RegistryFixture()
        let discovery = try fixture.discovery(targetHints: [])
        let identity = try CmxIrohIdentityMaterial(
            secretKey: CmxIrohSecretKey(bytes: fixture.privateKey.rawRepresentation),
            generation: fixture.initiator.identityGeneration
        )
        let configuration = CmxIrohClientRuntimeConfiguration(
            accountID: "account-a",
            deviceID: fixture.initiator.deviceID,
            appInstanceID: discovery.bindings[0].appInstanceID,
            tag: fixture.initiator.tag,
            displayName: nil,
            identity: identity,
            capabilities: discovery.bindings[0].capabilities,
            managedRelayURLs: [fixture.relayURL]
        )
        let relay = CmxIrohRelayTokenResponse(
            token: "testrelaytoken",
            expiresAt: "2027-01-15T10:00:00Z",
            refreshAfter: "2027-01-15T09:00:00Z",
            relayFleet: [fixture.relayURL]
        )
        let broker = TestIrohClientBroker(
            binding: discovery.bindings[0],
            discovery: discovery,
            relay: relay,
            pairGrant: try fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 3_600
            ),
            discoveryErrorsByCount: [
                2: CmxIrohTrustBrokerClientError.rateLimited(
                    code: "rate_limited",
                    retryAfterSeconds: 60
                ),
            ]
        )
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(
                endpoints: [TestIrohEndpoint(identity: fixture.initiator.endpointID)]
            ),
            broker: broker,
            configuration: configuration,
            pendingRevocations: CmxIrohPendingRevocationOutbox(
                secureStore: TestSecureCredentialStore()
            ),
            now: { fixture.now }
        )
        try await runtime.start()
        let provider = try #require(await runtime.registryContextProvider)

        _ = try await provider.context(for: fixture.request(hints: []))

        #expect(await broker.observedDiscoveryCount() == 1)
        await runtime.stop()
    }

    @Test
    func connectivityOnlyStartupRestoresVerifiedKnownMacRoutes() async throws {
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
        let identity = try CmxIrohIdentityMaterial(
            secretKey: CmxIrohSecretKey(bytes: fixture.privateKey.rawRepresentation),
            generation: fixture.initiator.identityGeneration
        )
        let configuration = CmxIrohClientRuntimeConfiguration(
            accountID: "account-a",
            deviceID: fixture.initiator.deviceID,
            appInstanceID: discovery.bindings[0].appInstanceID,
            tag: fixture.initiator.tag,
            displayName: nil,
            identity: identity,
            capabilities: discovery.bindings[0].capabilities,
            managedRelayURLs: [fixture.relayURL]
        )
        let relay = CmxIrohRelayTokenResponse(
            token: "testrelaytoken",
            expiresAt: "2027-01-15T10:00:00Z",
            refreshAfter: "2027-01-15T09:00:00Z",
            relayFleet: [fixture.relayURL]
        )
        let broker = TestIrohClientBroker(
            binding: discovery.bindings[0],
            discovery: discovery,
            relay: relay,
            registrationError: CmxIrohTrustBrokerClientError.connectivity
        )
        let recorder = ClientRuntimeTestRecorder()
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(
                endpoints: [TestIrohEndpoint(identity: fixture.initiator.endpointID)]
            ),
            broker: broker,
            configuration: configuration,
            pendingRevocations: CmxIrohPendingRevocationOutbox(
                secureStore: TestSecureCredentialStore()
            ),
            offlinePolicyCache: cache,
            now: { fixture.now },
            handleCachedBindings: { bindings, _ in
                await recorder.recordCachedBindings(bindings)
            }
        )

        try await runtime.start()

        #expect(await runtime.snapshot().state == .active)
        #expect(await runtime.snapshot().bindingID == discovery.bindings[0].bindingID)
        #expect(await recorder.observedCachedBindingDeviceIDs() == [[fixture.acceptor.deviceID]])
        await runtime.stop()
        #expect(await store.recordCount() == 1)
    }

    @Test
    func authenticatedStartupFailureNeverConsultsOfflinePolicy() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let store = TestSecureCredentialStore()
        let broker = TestIrohClientBroker(
            binding: fixture.binding,
            discovery: fixture.discovery,
            relay: fixture.relayResponse(),
            registrationError: CmxIrohTrustBrokerClientError.rejected(
                statusCode: 401,
                code: "unauthorized"
            )
        )
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(
                endpoints: [TestIrohEndpoint(identity: fixture.endpointID)]
            ),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            offlinePolicyCache: CmxIrohClientOfflinePolicyCache(secureStore: store),
            now: { fixture.now }
        )

        await #expect(throws: CmxIrohTrustBrokerClientError.rejected(
            statusCode: 401,
            code: "unauthorized"
        )) {
            try await runtime.start()
        }
        #expect(await store.readCount() == 0)
    }
}
