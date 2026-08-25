import CMUXMobileCore
import CryptoKit
import Foundation
import Testing

@testable import CmuxIrohTransport

extension CmxIrohHostRuntimeTests {
    @Test
    func startupFetchesAuthoritativeDiscoveryWhenRegistrationSnapshotIsIncomplete() async throws {
        let fixture = try HostRuntimeFixture()
        let pageOneBinding = try HostRuntimeFixture.binding(
            endpointID: fixture.endpointID.endpointID,
            bindingID: "123e4567-e89b-42d3-a456-426614174099"
        )
        let pageOne = try HostRuntimeFixture.discovery(
            binding: pageOneBinding,
            relays: HostRuntimeFixture.relayURLs,
            revision: 1
        )
        let completeDiscovery = try HostRuntimeFixture.discovery(
            binding: fixture.binding,
            relays: HostRuntimeFixture.relayURLs,
            revision: 1
        )
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: completeDiscovery,
            embeddedRegistrationDiscovery: pageOne,
            embeddedRegistrationDiscoveryIsComplete: false,
            registrationRevision: 1
        )
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [
                try fixture.relayReadyEndpoint(),
            ]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            handleTransport: { session, _ in await session.close() }
        )

        try await runtime.start()

        #expect(await broker.observedDiscoveryCount() == 1)
        #expect(await runtime.snapshot().state == .active)
        #expect(await runtime.connectivityEngine?.snapshot().routeRevision == 1)
        await runtime.stop()
    }

    @Test
    func truncatedEmbeddedDiscoveryFallsBackToAuthoritativeDiscovery() async throws {
        let fixture = try HostRuntimeFixture()
        let authoritative = try HostRuntimeFixture.discovery(
            binding: fixture.binding,
            relays: HostRuntimeFixture.relayURLs,
            revision: 7
        )
        let truncated = CmxIrohDiscoveryResponse(
            routeContractVersion: authoritative.routeContractVersion,
            revision: authoritative.revision,
            bindings: [],
            relayFleet: authoritative.relayFleet,
            lanRendezvous: authoritative.lanRendezvous,
            grantVerificationKeys: authoritative.grantVerificationKeys
        )
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: authoritative,
            embedDiscoveryInRegistration: true,
            embeddedRegistrationDiscovery: truncated
        )
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [
                TestIrohEndpoint(identity: fixture.endpointID),
            ]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            handleTransport: { session, _ in await session.close() }
        )

        try await runtime.start()

        #expect(await runtime.snapshot().state == .active)
        #expect(await broker.observedDiscoveryCount() == 1)
        await runtime.stop()
    }

    @Test
    func pendingRevocationInvalidatesEmbeddedRegistrationDiscovery() async throws {
        let fixture = try HostRuntimeFixture()
        let staleDiscovery = try HostRuntimeFixture.discovery(
            binding: fixture.binding,
            relays: HostRuntimeFixture.relayURLs,
            lanGeneration: 1,
            revision: 1
        )
        let authoritativeDiscovery = try HostRuntimeFixture.discovery(
            binding: fixture.binding,
            relays: HostRuntimeFixture.relayURLs,
            lanGeneration: 2,
            revision: 2
        )
        let pendingRevocations = fixture.pendingRevocations()
        let pending = try CmxIrohPendingRevocation(
            accountID: fixture.configuration.accountID,
            tag: "older-build",
            bindingID: "123e4567-e89b-42d3-a456-426614174099"
        )
        try await pendingRevocations.enqueue(pending)
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: authoritativeDiscovery,
            embeddedRegistrationDiscovery: staleDiscovery,
            embeddedRegistrationDiscoveryIsComplete: true,
            registrationRevision: 1
        )
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [
                try fixture.relayReadyEndpoint(),
            ]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: pendingRevocations,
            handleTransport: { session, _ in await session.close() }
        )

        try await runtime.start()

        #expect(await broker.observedRevokedBindingIDs() == [pending.bindingID])
        #expect(await broker.observedDiscoveryCount() == 1)
        #expect(await runtime.connectivityEngine?.snapshot().routeRevision == 2)
        #expect(await runtime.lanAdvertisementContext()?.rendezvous.generation == 2)
        await runtime.stop()
    }

    @Test
    func embeddedDiscoveryMustExactlyMatchTheRegistrationRevision() async throws {
        let fixture = try HostRuntimeFixture()
        let discovery = try HostRuntimeFixture.discovery(
            binding: fixture.binding,
            relays: HostRuntimeFixture.relayURLs,
            lanGeneration: 2,
            revision: 2
        )
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [
                TestIrohEndpoint(identity: fixture.endpointID),
            ]),
            broker: TestIrohHostBroker(
                registrationBinding: fixture.binding,
                discovery: discovery,
                embedDiscoveryInRegistration: true,
                registrationRevision: 1
            ),
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            handleTransport: { session, _ in await session.close() }
        )

        await #expect(throws: CmxIrohTrustBrokerClientError.invalidResponse) {
            try await runtime.start()
        }
    }

    @Test
    func embeddedDiscoveryCannotRegressTheInstalledAuthoritativeRevision() async throws {
        let fixture = try HostRuntimeFixture()
        let revisionTwo = try HostRuntimeFixture.discovery(
            binding: fixture.binding,
            relays: HostRuntimeFixture.relayURLs,
            lanGeneration: 2,
            revision: 2
        )
        let revisionOne = try HostRuntimeFixture.discovery(
            binding: fixture.binding,
            relays: HostRuntimeFixture.relayURLs,
            lanGeneration: 1,
            revision: 1
        )
        let endpoint = try fixture.relayReadyEndpoint()
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: revisionTwo,
            subsequentDiscoveries: [revisionOne],
            embedDiscoveryStartingAtRegistrationCount: 2
        )
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            handleTransport: { session, _ in await session.close() }
        )
        try await runtime.start()
        #expect(await runtime.connectivityEngine?.snapshot().routeRevision == 2)

        await runtime.requestRegistrationRefresh()
        for _ in 0..<1_000 {
            if await runtime.snapshot().state == .failed { break }
            await Task.yield()
        }

        #expect(await runtime.snapshot().state == .failed)
    }

    @Test
    func networkChangeDuringRegistrationIsObservedAfterStartup() async throws {
        let fixture = try HostRuntimeFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let recorder = HostRuntimeLANRefreshRecorder()
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            registrationHook: {
                await endpoint.emit(.networkChanged)
                return await recorder.waitForRefresh(timeout: .seconds(1))
            }
        )
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            handleTransport: { session, _ in await session.close() },
            handleLANRefresh: { await recorder.record() }
        )

        try await runtime.start()

        #expect(await broker.observedRegistrationHookResult() == true)
        #expect(await recorder.count() == 1)
        await runtime.stop()
    }

    @Test
    func networkChangeDuringActiveRefreshDoesNotRequestAnotherRegistration() async throws {
        let fixture = try HostRuntimeFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let gate = HostRuntimeRegistrationGate()
        let refreshes = HostRuntimeLANRefreshRecorder()
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            subsequentRegistrationHook: { await gate.waitOnce() }
        )
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            handleTransport: { session, _ in await session.close() },
            handleLANRefresh: { await refreshes.record() }
        )
        try await runtime.start()

        let refresh = Task { await runtime.requestRegistrationRefresh() }
        await broker.waitForRegistrationCount(2)
        await endpoint.emit(.networkChanged)
        #expect(await refreshes.waitForCount(1, timeout: .seconds(1)))
        await gate.open()
        await refresh.value

        let registeredAgain = await broker.waitForRegistrationCount(
            3,
            timeout: .milliseconds(200)
        )
        #expect(!registeredAgain)
        await runtime.stop()
    }

    @Test
    func refreshedVerifiedRendezvousReplacesPublishedLANPolicy() async throws {
        let fixture = try HostRuntimeFixture()
        let refreshedDiscovery = try HostRuntimeFixture.discovery(
            binding: fixture.binding,
            relays: Array(fixture.managedRelays),
            lanGeneration: 2
        )
        let endpoint = TestIrohEndpoint(
            identity: fixture.endpointID,
            directAddresses: ["192.168.1.10:50906"]
        )
        let policies = HostRuntimeLANPolicyRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: TestIrohHostBroker(
                registrationBinding: fixture.binding,
                discovery: fixture.discovery,
                subsequentDiscoveries: [refreshedDiscovery]
            ),
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            handleTransport: { session, _ in await session.close() },
            handleLANPolicy: { context, directAddresses in
                await policies.record(
                    context: context,
                    directAddresses: await directAddresses()
                )
            }
        )
        try await runtime.start()
        await runtime.requestRegistrationRefresh()
        await policies.waitForCount(2)

        #expect(await policies.contexts().map(\.rendezvous.generation) == [1, 2])
        #expect(await policies.addresses() == [
            ["192.168.1.10:50906"],
            ["192.168.1.10:50906"],
        ])
        #expect(await runtime.lanAdvertisementContext()?.rendezvous.generation == 2)
        await runtime.stop()
    }

    @Test(arguments: [
        CmxIrohTrustBrokerClientError.missingAuthentication,
        .rejected(statusCode: 400, code: "invalid_request"),
        .invalidResponse,
    ])
    func terminalBrokerFailureFailsClosedAfterCacheFirstActivation(
        _ failure: CmxIrohTrustBrokerClientError
    ) async throws {
        let fixture = try HostRuntimeFixture()
        let cachedFixture = try fixture.cachedPolicyFixture()
        let now = cachedFixture.now
        let endpoint = try fixture.relayReadyEndpoint()
        let factory = TestIrohEndpointFactory(endpoints: [endpoint])
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            registrationError: failure
        )
        let bindings = HostRuntimeBindingRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: factory,
            broker: broker,
            configuration: fixture.configuration(
                cachedHostPolicy: try cachedFixture.policy()
            ),
            pendingRevocations: fixture.pendingRevocations(),
            now: { now },
            handleTransport: { session, _ in await session.close() },
            handleBinding: { _, _, _ in await bindings.record() }
        )

        // Cache-first activation succeeds locally, but the background live
        // reconcile discovers the terminal rejection and fails closed: a Mac
        // the broker refuses must not keep serving on cached authority.
        try await runtime.start()
        await runtime.waitForInitialPublicationForTesting()

        #expect(await runtime.snapshot().state == .failed)
        #expect(await endpoint.waitForCloseCallCount(1))
        #expect(await bindings.count() == 0)
    }

    @Test
    func onlinePolicySupersedesAValidCachedBinding() async throws {
        let fixture = try HostRuntimeFixture()
        let cachedMetadata = try CmxIrohBrokerBindingMetadata(
            bindingID: "123e4567-e89b-42d3-a456-426614174099",
            deviceID: fixture.binding.deviceID,
            appInstanceID: fixture.binding.appInstanceID,
            tag: fixture.binding.tag,
            platform: .mac,
            endpointID: fixture.binding.endpointID,
            identityGeneration: fixture.binding.identityGeneration
        )
        let cachedFixture = try fixture.cachedPolicyFixture(binding: cachedMetadata)
        let now = cachedFixture.now
        let endpoint = try fixture.relayReadyEndpoint()
        let factory = TestIrohEndpointFactory(endpoints: [endpoint])
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery
        )
        let bindings = HostRuntimeBindingRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: factory,
            broker: broker,
            configuration: fixture.configuration(
                cachedHostPolicy: try cachedFixture.policy()
            ),
            pendingRevocations: fixture.pendingRevocations(),
            now: { now },
            handleTransport: { session, _ in await session.close() },
            handleBinding: { _, _, _ in await bindings.record() }
        )

        // Cache-first activation starts on the persisted binding; the live
        // reconcile discovers it was replaced server-side and adopts the
        // authenticated binding in place, publishing it exactly once.
        try await runtime.start()
        await runtime.waitForInitialPublicationForTesting()

        #expect(await runtime.snapshot().state == .active)
        #expect(await runtime.snapshot().bindingID == fixture.binding.bindingID)
        #expect(await bindings.count() == 1)
        await runtime.stop()
    }

    @Test
    func cachedConnectivityFallbackPublishesResolvedBinding() async throws {
        let fixture = try HostRuntimeFixture()
        let cachedFixture = try fixture.cachedPolicyFixture()
        let now = cachedFixture.now
        let resolvedBindings = HostRuntimeResolvedBindingRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(
                endpoints: [TestIrohEndpoint(identity: fixture.endpointID)]
            ),
            broker: TestIrohHostBroker(
                registrationBinding: fixture.binding,
                discovery: fixture.discovery,
                registrationError: .connectivity
            ),
            configuration: fixture.configuration(
                cachedHostPolicy: try cachedFixture.policy()
            ),
            pendingRevocations: fixture.pendingRevocations(),
            now: { now },
            handleTransport: { session, _ in await session.close() },
            handleRoute: { binding, _ in
                await resolvedBindings.record(binding)
            }
        )

        try await runtime.start()

        #expect(await resolvedBindings.values() == [cachedFixture.binding])
        await runtime.stop()
    }

    @Test
    func forgedCachedPolicyFailsAfterConnectivityFailure() async throws {
        let fixture = try HostRuntimeFixture()
        let cachedFixture = try fixture.cachedPolicyFixture()
        let now = cachedFixture.now
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let factory = TestIrohEndpointFactory(endpoints: [endpoint])
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            registrationError: .connectivity
        )
        let runtime = CmxIrohHostRuntime(
            factory: factory,
            broker: broker,
            configuration: fixture.configuration(
                cachedHostPolicy: try cachedFixture.policySignedByOriginalKey(
                    publishedKeySet: cachedFixture.alternateKeySet
                )
            ),
            pendingRevocations: fixture.pendingRevocations(),
            now: { now },
            handleTransport: { session, _ in await session.close() }
        )

        await #expect(throws: CmxIrohGrantVerifierError.invalidSignature) {
            try await runtime.start()
        }

        #expect(await endpoint.observedCloseCallCount() == 1)
        #expect(await runtime.snapshot().state == .failed)
    }

    @Test
    func halfConfirmedBindingChangeIsNeverAdoptedNorPublished() async throws {
        let fixture = try HostRuntimeFixture()
        let cachedFixture = try fixture.cachedPolicyFixture()
        let now = cachedFixture.now
        let changedBinding = try HostRuntimeFixture.binding(
            endpointID: fixture.endpointID.endpointID,
            bindingID: "123e4567-e89b-42d3-a456-426614174099"
        )
        let endpoint = try fixture.relayReadyEndpoint()
        let factory = TestIrohEndpointFactory(endpoints: [endpoint])
        let broker = TestIrohHostBroker(
            registrationBinding: changedBinding,
            discovery: fixture.discovery,
            discoveryError: .connectivity
        )
        let bindings = HostRuntimeBindingRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: factory,
            broker: broker,
            configuration: fixture.configuration(
                cachedHostPolicy: try cachedFixture.policy()
            ),
            pendingRevocations: fixture.pendingRevocations(),
            now: { now },
            handleTransport: { session, _ in await session.close() },
            handleBinding: { _, _, _ in await bindings.record() }
        )

        // The reconcile registers a replaced binding but its discovery round
        // fails on connectivity. The half-confirmed binding is confirmed
        // proof that cached authority is stale, so the runtime fails closed
        // without adopting or publishing the incomplete policy.
        try await runtime.start()
        await runtime.waitForInitialPublicationForTesting()

        #expect(await runtime.snapshot().state == .failed)
        #expect(await bindings.count() == 0)
        #expect(await endpoint.observedCloseCallCount() == 1)
    }

    @Test
    func routeContractMismatchFailsClosedAfterCacheFirstActivation() async throws {
        let fixture = try HostRuntimeFixture()
        let cachedFixture = try fixture.cachedPolicyFixture()
        let now = cachedFixture.now
        let mismatchedDiscovery = try HostRuntimeFixture.discovery(
            binding: fixture.binding,
            relays: Array(fixture.managedRelays),
            routeContractVersion: 2
        )
        let endpoint = try fixture.relayReadyEndpoint()
        let factory = TestIrohEndpointFactory(endpoints: [endpoint])
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: mismatchedDiscovery
        )
        let runtime = CmxIrohHostRuntime(
            factory: factory,
            broker: broker,
            configuration: fixture.configuration(
                cachedHostPolicy: try cachedFixture.policy()
            ),
            pendingRevocations: fixture.pendingRevocations(),
            now: { now },
            handleTransport: { session, _ in await session.close() }
        )

        try await runtime.start()
        await runtime.waitForInitialPublicationForTesting()

        #expect(await runtime.snapshot().state == .failed)
        #expect(await endpoint.waitForCloseCallCount(1))
    }

    @Test
    func discoverySubstitutionFailsClosedAndClosesEndpoint() async throws {
        let fixture = try HostRuntimeFixture()
        let endpoint = try fixture.relayReadyEndpoint()
        let factory = TestIrohEndpointFactory(endpoints: [endpoint])
        let substituted = try HostRuntimeFixture.discovery(
            binding: fixture.binding,
            relays: Array(fixture.managedRelays),
            overrideDeviceID: "123e4567-e89b-42d3-a456-426614174099"
        )
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: substituted
        )
        let cachedFixture = try fixture.cachedPolicyFixture()
        let now = cachedFixture.now
        let runtime = CmxIrohHostRuntime(
            factory: factory,
            broker: broker,
            configuration: fixture.configuration(
                cachedHostPolicy: try cachedFixture.policy()
            ),
            pendingRevocations: fixture.pendingRevocations(),
            now: { now },
            handleTransport: { session, _ in await session.close() }
        )

        try await runtime.start()
        await runtime.waitForInitialPublicationForTesting()

        #expect(await runtime.snapshot().state == .failed)
        #expect(await endpoint.waitForCloseCallCount(1))
    }
}

private actor HostRuntimeResolvedBindingRecorder {
    private var bindings: [CmxIrohBrokerBindingMetadata] = []

    func record(_ binding: CmxIrohBrokerBindingMetadata) {
        bindings.append(binding)
    }

    func values() -> [CmxIrohBrokerBindingMetadata] {
        bindings
    }
}
