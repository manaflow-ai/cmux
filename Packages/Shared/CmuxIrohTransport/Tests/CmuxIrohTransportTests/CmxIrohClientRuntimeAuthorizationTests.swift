import CMUXMobileCore
import CryptoKit
import Testing
@testable import CmuxIrohTransport

extension CmxIrohClientRuntimeTests {
    /// The startup snapshot here advertises NO usable target paths, so the
    /// first dial performs one empty-plan rescue fetch (docs/transport-plane.md,
    /// D5: reuse windows apply only to healthy-plan dials). When the broker
    /// rate-limits that duplicate lookup, the dial still proceeds on the
    /// startup snapshot: exactly two lookups, no spin, no failure.
    @Test
    func firstDialOnHintlessStartupDiscoverySurvivesRateLimitedRescueFetch() async throws {
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
            clientNamespace: discovery.bindings[0].clientNamespace,
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

        let context = try await provider.context(for: fixture.request(hints: []))

        #expect(await broker.observedDiscoveryCount() == 2)
        #expect(context.dialPlan.publicPaths.isEmpty)
        await runtime.stop()
    }

    /// A presence route push invalidates one Mac's reusable discovery through
    /// the runtime seam: the next dial must refetch instead of consuming the
    /// startup snapshot (docs/transport-plane.md, D5).
    @Test
    func presenceInvalidationThroughRuntimeForcesFreshDiscoveryOnNextDial() async throws {
        let fixture = try RegistryFixture()
        let relayHint = try CmxIrohPathHint(
            kind: .relayURL,
            value: fixture.relayURL,
            source: .native,
            privacyScope: .publicInternet,
            observedAt: fixture.now,
            expiresAt: fixture.now.addingTimeInterval(60)
        )
        let discovery = try fixture.discovery(targetHints: [relayHint])
        let identity = try CmxIrohIdentityMaterial(
            secretKey: CmxIrohSecretKey(bytes: fixture.privateKey.rawRepresentation),
            generation: fixture.initiator.identityGeneration
        )
        let configuration = CmxIrohClientRuntimeConfiguration(
            accountID: "account-a",
            deviceID: fixture.initiator.deviceID,
            appInstanceID: discovery.bindings[0].appInstanceID,
            clientNamespace: discovery.bindings[0].clientNamespace,
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
            )
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
        #expect(await broker.observedDiscoveryCount() == 1)

        await runtime.invalidateDiscoverySnapshot(
            forMacDeviceID: fixture.acceptor.deviceID
        )

        let context = try await provider.context(for: fixture.request(hints: []))
        #expect(await broker.observedDiscoveryCount() == 2)
        #expect(context.dialPlan.publicPaths == [relayHint])
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
            clientNamespace: discovery.bindings[0].clientNamespace,
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
            registrationError: CmxIrohTrustBrokerClientError.connectivity(nil)
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
