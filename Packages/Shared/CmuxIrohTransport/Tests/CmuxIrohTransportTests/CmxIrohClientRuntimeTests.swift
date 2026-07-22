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
            pendingRevocations: fixture.pendingRevocations(),
            now: { fixture.now },
            handleBinding: { _, _ in
                await recorder.recordBinding()
                return true
            },
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
        await recorder.waitForRelayCount(1)
        #expect(await recorder.observedRelayCount() == 1)
        #expect(runtime.transportFactory.supportedKinds == [.iroh])
        await runtime.stop()
    }

    @Test
    func liveDiscoveryRefreshReturnsTrueOnlyAfterNewVerifiedSnapshot() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let broker = TestIrohClientBroker(
            binding: fixture.binding,
            discovery: fixture.discovery,
            relay: fixture.relayResponse()
        )
        let recorder = ClientRuntimeTestRecorder()
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [
                TestIrohEndpoint(identity: fixture.endpointID),
            ]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { fixture.now },
            handleBinding: { _, _ in
                await recorder.recordBinding()
                return true
            }
        )
        try await runtime.start()

        let initialProvider = try #require(await runtime.registryContextProvider)
        #expect(await runtime.refreshLiveDiscovery())
        let refreshedProvider = try #require(await runtime.registryContextProvider)
        #expect(await broker.observedRegistrations().count == 2)
        #expect(await recorder.observedBindingCount() == 2)
        #expect(initialProvider === refreshedProvider)
        await runtime.stop()
    }

    @Test
    func unavailableBrokerReportsOfflineWithoutReusingStaleDiscovery() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let broker = TestIrohClientBroker(
            binding: fixture.binding,
            discovery: fixture.discovery,
            relay: fixture.relayResponse()
        )
        let recorder = ClientRuntimeTestRecorder()
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [
                TestIrohEndpoint(identity: fixture.endpointID),
            ]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { fixture.now },
            handleBinding: { _, _ in
                await recorder.recordBinding()
                return true
            }
        )
        try await runtime.start()
        await broker.setRegistrationError(CmxIrohTrustBrokerClientError.connectivity)

        #expect(
            await runtime.refreshLiveDiscoveryOutcome()
                == .failed(.offline)
        )
        #expect(await runtime.snapshot().state == .active)
        #expect(await recorder.observedBindingCount() == 1)
        await runtime.stop()
    }

    @Test
    func rateLimitedBrokerReportsPolicyUnavailableWithoutDroppingRuntime() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let broker = TestIrohClientBroker(
            binding: fixture.binding,
            discovery: fixture.discovery,
            relay: fixture.relayResponse()
        )
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [
                TestIrohEndpoint(identity: fixture.endpointID),
            ]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { fixture.now }
        )
        try await runtime.start()
        await broker.setRegistrationError(
            CmxIrohTrustBrokerClientError.rateLimited(
                code: nil,
                retryAfterSeconds: 15
            )
        )

        #expect(
            await runtime.refreshLiveDiscoveryOutcome()
                == .failed(.policyUnavailable)
        )
        #expect(await runtime.snapshot().state == .active)
        await runtime.stop()
    }

    @Test
    func rejectedCatalogPublicationCannotAdvanceLiveDiscoveryGeneration() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [
                TestIrohEndpoint(identity: fixture.endpointID),
            ]),
            broker: TestIrohClientBroker(
                binding: fixture.binding,
                discovery: fixture.discovery,
                relay: fixture.relayResponse()
            ),
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { fixture.now },
            handleBinding: { _, _ in false }
        )

        try await runtime.start()
        #expect(await runtime.liveDiscoverySnapshotGeneration() == 0)
        #expect(
            await runtime.refreshLiveDiscoveryOutcome()
                == .failed(.superseded)
        )
        #expect(await runtime.liveDiscoverySnapshotGeneration() == 0)
        await runtime.stop()
    }

    @Test
    func inactiveRuntimeReportsEndpointUnavailable() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: []),
            broker: TestIrohClientBroker(
                binding: fixture.binding,
                discovery: fixture.discovery,
                relay: fixture.relayResponse()
            ),
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { fixture.now }
        )

        #expect(
            await runtime.refreshLiveDiscoveryOutcome()
                == .failed(.endpointUnavailable)
        )
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
            pendingRevocations: fixture.pendingRevocations(),
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
            pendingRevocations: fixture.pendingRevocations(),
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
            pendingRevocations: fixture.pendingRevocations(),
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
            pendingRevocations: fixture.pendingRevocations(),
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
            pendingRevocations: fixture.pendingRevocations(),
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

    @Test(arguments: [
        CmxIrohTrustBrokerClientError.rejected(
            statusCode: 408,
            code: "request_timeout"
        ),
        .rejected(statusCode: 425, code: "too_early"),
        CmxIrohTrustBrokerClientError.rejected(
            statusCode: 429,
            code: "challenge_rate_limited"
        ),
        .rejected(statusCode: 503, code: "unavailable"),
    ])
    func foregroundAvailabilityFailureKeepsLastVerifiedPolicy(
        _ failure: CmxIrohTrustBrokerClientError
    ) async throws {
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
            pendingRevocations: fixture.pendingRevocations(),
            offlinePolicyCache: CmxIrohClientOfflinePolicyCache(
                secureStore: offlineStore
            ),
            now: { fixture.now },
            handlePolicyInvalidation: {
                await recorder.recordPolicyInvalidation()
            }
        )
        try await runtime.start()
        await broker.setRegistrationError(failure)

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
                let endpointWasClosed = await endpoint.observedCloseCallCount() == 1
                let pendingCount = try? await pendingRevocations.pending(
                    accountID: fixture.configuration.accountID
                ).count
                let offlineWasDeactivated = await offlineStore.deleteAllCount() == 1
                await recorder.recordLocalWipe(
                    endpointWasClosed: endpointWasClosed
                        && pendingCount == 1
                        && offlineWasDeactivated
                )
            }
        )
        try await runtime.start()

        let preparation = await runtime.deactivateForSignOut()

        #expect(preparation.bindingID == fixture.binding.bindingID)
        #expect(preparation.wasPersisted)
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
    func suspendedSignOutPersistenceBlocksRestartUntilLocalTeardownCompletes() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let store = TestControllableSecureCredentialStore()
        let pendingRevocations = CmxIrohPendingRevocationOutbox(secureStore: store)
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: TestIrohClientBroker(
                binding: fixture.binding,
                discovery: fixture.discovery,
                relay: fixture.relayResponse()
            ),
            configuration: fixture.configuration,
            pendingRevocations: pendingRevocations,
            now: { fixture.now }
        )
        try await runtime.start()
        await store.suspendNextWrite()

        let signOut = Task { await runtime.deactivateForSignOut() }
        await store.waitUntilWriteIsSuspended()

        let signingOut = await runtime.snapshot()
        #expect(signingOut.state == .signingOut)
        #expect(signingOut.bindingID == fixture.binding.bindingID)
        await #expect(throws: CmxIrohClientRuntimeError.alreadyActive) {
            try await runtime.start()
        }

        await store.resumeSuspendedWrite()
        let preparation = await signOut.value
        #expect(preparation.wasPersisted)
        #expect(await endpoint.observedCloseCallCount() == 1)
        #expect(await runtime.snapshot().state == .inactive)
    }

    @Test
    func failedSignOutPersistenceClosesEndpointAndQuarantinesLocalState() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let store = TestControllableSecureCredentialStore()
        let pendingRevocations = CmxIrohPendingRevocationOutbox(secureStore: store)
        let offlineStore = TestSecureCredentialStore()
        let recorder = ClientRuntimeTestRecorder()
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: TestIrohClientBroker(
                binding: fixture.binding,
                discovery: fixture.discovery,
                relay: fixture.relayResponse()
            ),
            configuration: fixture.configuration,
            pendingRevocations: pendingRevocations,
            offlinePolicyCache: CmxIrohClientOfflinePolicyCache(
                secureStore: offlineStore
            ),
            now: { fixture.now },
            handleLocalDeactivation: {
                await recorder.recordLocalWipe(endpointWasClosed: true)
            }
        )
        try await runtime.start()
        await store.failNextWrite()

        let preparation = await runtime.deactivateForSignOut()

        #expect(preparation.bindingID == fixture.binding.bindingID)
        #expect(!preparation.wasPersisted)
        #expect(await endpoint.observedCloseCallCount() == 1)
        #expect(await offlineStore.deleteAllCount() == 0)
        #expect(await recorder.observedLocalWipes().isEmpty)
        let quarantined = await runtime.snapshot()
        #expect(quarantined.state == .quarantined)
        #expect(quarantined.endpointID == nil)
        #expect(quarantined.bindingID == fixture.binding.bindingID)
        await #expect(throws: CmxIrohClientRuntimeError.alreadyActive) {
            try await runtime.start()
        }

        let retried = await runtime.deactivateForSignOut()
        #expect(retried.wasPersisted)
        #expect(await offlineStore.deleteAllCount() == 1)
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

}
