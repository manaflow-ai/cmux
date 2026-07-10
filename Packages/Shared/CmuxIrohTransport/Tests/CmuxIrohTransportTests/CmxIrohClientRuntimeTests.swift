import CMUXMobileCore
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohClientRuntimeTests {
    @Test
    func startInstallsExactIOSBindingAndManagedRelays() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let factory = TestIrohEndpointFactory(endpoints: [endpoint])
        let broker = TestIrohClientBroker(
            binding: fixture.binding,
            discovery: fixture.discovery,
            relay: fixture.relayResponse()
        )
        let recorder = ClientRuntimeTestRecorder()
        let runtime = try CmxIrohClientRuntime(
            factory: factory,
            broker: broker,
            configuration: fixture.configuration,
            now: { fixture.now },
            handleBinding: { _, _ in await recorder.recordBinding() },
            handleRelayCredential: { _, _ in await recorder.recordRelay() }
        )

        try await runtime.start()

        let snapshot = await runtime.snapshot()
        #expect(snapshot.state == .active)
        #expect(snapshot.endpointID == fixture.endpointID)
        #expect(snapshot.bindingID == fixture.binding.bindingID)
        let prepared = try #require(await broker.observedRegistrations().first)
        #expect(prepared.challengeRequest.deviceId == fixture.binding.deviceID)
        #expect(prepared.challengeRequest.appInstanceId == fixture.binding.appInstanceID)
        #expect(prepared.challengeRequest.tag == fixture.binding.tag)
        #expect(prepared.challengeRequest.endpointId == fixture.endpointID.endpointID)
        #expect(prepared.challengeRequest.identityGeneration == fixture.identity.generation)
        #expect(await endpoint.observedRelayUpdates().last?.count == 4)
        #expect(await recorder.observedBindingCount() == 1)
        #expect(await recorder.observedRelayCount() == 1)
        #expect(runtime.transportFactory.supportedKinds == [.iroh])
        await runtime.stop()
    }

    @Test
    func discoverySubstitutionFailsClosedAndClosesEndpoint() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let substitutedDiscovery = try ClientRuntimeTestFixture.discovery(
            binding: fixture.binding,
            overrideAppInstanceID: "123e4567-e89b-42d3-a456-426614174099"
        )
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let broker = TestIrohClientBroker(
            binding: fixture.binding,
            discovery: substitutedDiscovery,
            relay: fixture.relayResponse()
        )
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            now: { fixture.now }
        )

        await #expect(throws: CmxIrohClientRuntimeError.localBindingMissingFromDiscovery) {
            try await runtime.start()
        }

        #expect(await endpoint.observedCloseCallCount() == 1)
        #expect(await runtime.snapshot().state == .failed)
    }

    @Test
    func backgroundPreservesEndpointAndForegroundReusesHealthyGeneration() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let factory = TestIrohEndpointFactory(endpoints: [endpoint])
        let broker = TestIrohClientBroker(
            binding: fixture.binding,
            discovery: fixture.discovery,
            relay: fixture.relayResponse()
        )
        let runtime = try CmxIrohClientRuntime(
            factory: factory,
            broker: broker,
            configuration: fixture.configuration,
            now: { fixture.now }
        )
        try await runtime.start()

        await runtime.didEnterBackground()
        try await runtime.didBecomeActive()

        #expect(await endpoint.observedCloseCallCount() == 0)
        #expect(await factory.observedConfigurations().count == 1)
        #expect(await broker.observedRegistrations().count == 2)
        #expect(await runtime.snapshot().state == .active)
        await runtime.stop()
    }

    @Test
    func foregroundRecreatesStaleDriverWithStableIdentity() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let staleEndpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let replacementEndpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let factory = TestIrohEndpointFactory(
            endpoints: [staleEndpoint, replacementEndpoint]
        )
        let broker = TestIrohClientBroker(
            binding: fixture.binding,
            discovery: fixture.discovery,
            relay: fixture.relayResponse()
        )
        let runtime = try CmxIrohClientRuntime(
            factory: factory,
            broker: broker,
            configuration: fixture.configuration,
            now: { fixture.now }
        )
        try await runtime.start()
        await runtime.didEnterBackground()
        await staleEndpoint.setHealthy(false)

        try await runtime.didBecomeActive()

        let configurations = await factory.observedConfigurations()
        #expect(configurations.count == 2)
        #expect(configurations[0].secretKey == configurations[1].secretKey)
        #expect(await staleEndpoint.observedCloseCallCount() == 1)
        #expect(await broker.observedRegistrations().count == 2)
        #expect(await runtime.snapshot().endpointID == fixture.endpointID)
        await runtime.stop()
    }

    @Test
    func foregroundTerminalBrokerFailureRevokesLocalPolicy() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let broker = TestIrohClientBroker(
            binding: fixture.binding,
            discovery: fixture.discovery,
            relay: fixture.relayResponse()
        )
        let offlineStore = TestSecureCredentialStore()
        let recorder = ClientRuntimeTestRecorder()
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            offlinePolicyCache: CmxIrohClientOfflinePolicyCache(
                secureStore: offlineStore
            ),
            now: { fixture.now },
            handlePolicyInvalidation: {
                await recorder.recordPolicyInvalidation()
            }
        )
        try await runtime.start()
        let terminal = CmxIrohTrustBrokerClientError.rejected(
            statusCode: 401,
            code: "unauthorized"
        )
        await broker.setRegistrationError(terminal)

        await #expect(throws: terminal) {
            try await runtime.didBecomeActive()
        }

        #expect(await runtime.snapshot().state == .failed)
        #expect(await endpoint.observedCloseCallCount() == 1)
        #expect(await offlineStore.deleteAllCount() == 1)
        #expect(await recorder.observedPolicyInvalidationCount() == 1)
    }

    @Test
    func foregroundConnectivityFailureKeepsLastVerifiedPolicy() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let broker = TestIrohClientBroker(
            binding: fixture.binding,
            discovery: fixture.discovery,
            relay: fixture.relayResponse()
        )
        let offlineStore = TestSecureCredentialStore()
        let recorder = ClientRuntimeTestRecorder()
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            offlinePolicyCache: CmxIrohClientOfflinePolicyCache(
                secureStore: offlineStore
            ),
            now: { fixture.now },
            handlePolicyInvalidation: {
                await recorder.recordPolicyInvalidation()
            }
        )
        try await runtime.start()
        await broker.setRegistrationError(CmxIrohTrustBrokerClientError.connectivity)

        try await runtime.didBecomeActive()

        #expect(await runtime.snapshot().state == .active)
        #expect(await endpoint.observedCloseCallCount() == 0)
        #expect(await offlineStore.deleteAllCount() == 0)
        #expect(await recorder.observedPolicyInvalidationCount() == 0)
        await runtime.stop()
    }

    @Test
    func signOutWipesLocallyBeforeBestEffortRemoteRevocation() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let broker = TestIrohClientBroker(
            binding: fixture.binding,
            discovery: fixture.discovery,
            relay: fixture.relayResponse(),
            revokeError: TestIrohTransportError.unsupported
        )
        let recorder = ClientRuntimeTestRecorder()
        let offlineStore = TestSecureCredentialStore()
        let pendingRevocations = CmxIrohPendingRevocationOutbox(
            secureStore: TestSecureCredentialStore()
        )
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: pendingRevocations,
            offlinePolicyCache: CmxIrohClientOfflinePolicyCache(
                secureStore: offlineStore
            ),
            now: { fixture.now },
            handleLocalDeactivation: {
                await recorder.recordLocalWipe(
                    endpointWasClosed: await endpoint.observedCloseCallCount() == 1
                        && (try? await pendingRevocations.pending(
                            accountID: fixture.configuration.accountID
                        ).count) == 1
                )
            }
        )
        try await runtime.start()

        let preparation = await runtime.deactivateForSignOut()

        #expect(preparation.bindingID == fixture.binding.bindingID)
        #expect(await recorder.observedLocalWipes() == [true])
        #expect(await offlineStore.deleteAllCount() == 1)
        #expect(await runtime.snapshot().state == .inactive)
        await #expect(throws: TestIrohTransportError.unsupported) {
            try await preparation.revoke(
                using: broker,
                pendingRevocations: pendingRevocations
            )
        }
        #expect(await broker.observedRevokedBindingIDs() == [fixture.binding.bindingID])
        #expect(
            try await pendingRevocations.pending(
                accountID: fixture.configuration.accountID
            ).count == 1
        )
        #expect(await recorder.observedLocalWipes() == [true])
        #expect(await runtime.snapshot().state == .inactive)
    }

    @Test
    func pendingRevocationFailureBlocksRegistrationAndOfflineFallback() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let store = TestSecureCredentialStore()
        let pendingRevocations = CmxIrohPendingRevocationOutbox(secureStore: store)
        let pending = try CmxIrohPendingRevocation(
            accountID: fixture.configuration.accountID,
            tag: "older-build",
            bindingID: "123e4567-e89b-42d3-a456-426614174099"
        )
        try await pendingRevocations.enqueue(pending)
        let broker = TestIrohClientBroker(
            binding: fixture.binding,
            discovery: fixture.discovery,
            relay: fixture.relayResponse(),
            revokeError: CmxIrohTrustBrokerClientError.connectivity
        )
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(
                endpoints: [TestIrohEndpoint(identity: fixture.endpointID)]
            ),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: pendingRevocations,
            offlinePolicyCache: CmxIrohClientOfflinePolicyCache(
                secureStore: TestSecureCredentialStore()
            ),
            now: { fixture.now }
        )

        await #expect(throws: CmxIrohTrustBrokerClientError.connectivity) {
            try await runtime.start()
        }

        #expect(await broker.observedRegistrations().isEmpty)
        #expect(await broker.observedRevokedBindingIDs() == [pending.bindingID])
        #expect(
            try await pendingRevocations.pending(
                accountID: fixture.configuration.accountID
            ) == [pending]
        )
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
