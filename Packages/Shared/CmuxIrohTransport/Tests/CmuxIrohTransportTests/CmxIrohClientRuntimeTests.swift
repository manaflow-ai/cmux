import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

private extension CmxIrohClientRuntime {
    func installLocalBindingForSignOutTest(_ binding: CmxIrohBrokerBinding) {
        localBinding = binding
    }
}

@Suite
struct CmxIrohClientRuntimeTests {
    @Test
    func cachedFastPathRejectsAReplacedLiveEndpointIdentity() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let substitutedIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "0", count: 64)
        )
        let discovery = try ClientRuntimeTestFixture.discovery(
            binding: fixture.binding,
            revision: 1
        )
        let configuration = CmxIrohClientRuntimeConfiguration(
            accountID: fixture.configuration.accountID,
            deviceID: fixture.configuration.deviceID,
            appInstanceID: fixture.configuration.appInstanceID,
            clientNamespace: fixture.configuration.clientNamespace,
            tag: fixture.configuration.tag,
            displayName: fixture.configuration.displayName,
            identity: fixture.configuration.identity,
            capabilities: fixture.configuration.capabilities,
            managedRelayURLs: fixture.configuration.managedRelayURLs,
            cachedBinding: CmxIrohBrokerBindingMetadata(binding: fixture.binding)
        )
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [
                TestSubstitutedAddressEndpoint(
                    identity: fixture.endpointID,
                    addressIdentity: substitutedIdentity
                ),
            ]),
            broker: TestRevisionedClientBroker(
                binding: fixture.binding,
                discoveries: [discovery]
            ),
            configuration: configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { fixture.now }
        )

        await #expect(throws: CmxIrohClientRuntimeError.invalidLocalBinding) {
            try await runtime.start()
        }
    }

    @Test
    func discoveryCannotPrecedeTheRegistrationRevision() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let discovery = try ClientRuntimeTestFixture.discovery(
            binding: fixture.binding,
            revision: 1
        )
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [
                TestIrohEndpoint(identity: fixture.endpointID),
            ]),
            broker: TestRevisionedClientBroker(
                binding: fixture.binding,
                discoveries: [discovery],
                registrationRevision: 2
            ),
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { fixture.now }
        )

        await #expect(throws: CmxIrohTrustBrokerClientError.invalidResponse) {
            try await runtime.start()
        }
    }

    @Test
    func embeddedDiscoveryMayFollowTheRegistrationRevision() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let discovery = try ClientRuntimeTestFixture.discovery(
            binding: fixture.binding,
            revision: 2
        )
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [
                TestIrohEndpoint(identity: fixture.endpointID),
            ]),
            broker: TestRevisionedClientBroker(
                binding: fixture.binding,
                discoveries: [discovery],
                embedInitialDiscovery: true,
                registrationRevision: 1
            ),
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { fixture.now }
        )

        try await runtime.start()

        #expect(await runtime.snapshot().state == .active)
        #expect(await runtime.connectivityEngine.snapshot().routeRevision == 2)
        await runtime.stop()
    }

    @Test
    func authoritativeRejectionCannotFallBackToStaleOfflineAuthority() async throws {
        let fixture = try RegistryFixture()
        let accepted = try fixture.discovery(targetHints: [])
        let acceptedRevision = CmxIrohDiscoveryResponse(
            routeContractVersion: accepted.routeContractVersion,
            revision: 1,
            bindings: accepted.bindings,
            relayFleet: accepted.relayFleet,
            lanRendezvous: accepted.lanRendezvous,
            grantVerificationKeys: accepted.grantVerificationKeys
        )
        let rejectedRevision = CmxIrohDiscoveryResponse(
            routeContractVersion: accepted.routeContractVersion,
            revision: 2,
            bindings: Array(accepted.bindings.dropFirst()),
            relayFleet: accepted.relayFleet,
            lanRendezvous: accepted.lanRendezvous,
            grantVerificationKeys: accepted.grantVerificationKeys
        )
        let localBinding = try #require(accepted.bindings.first)
        let targetBinding = try #require(accepted.bindings.dropFirst().first)
        let cache = CmxIrohClientOfflinePolicyCache(
            secureStore: TestSecureCredentialStore()
        )
        try await cache.save(
            localBinding: localBinding,
            targetBinding: targetBinding,
            discovery: acceptedRevision,
            pairGrant: fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 3_600
            ),
            for: fixture.offlineExpectation(),
            now: fixture.now
        )
        let identity = try CmxIrohIdentityMaterial(
            secretKey: CmxIrohSecretKey(bytes: fixture.privateKey.rawRepresentation),
            generation: fixture.initiator.identityGeneration
        )
        let configuration = CmxIrohClientRuntimeConfiguration(
            accountID: "account-a",
            deviceID: fixture.initiator.deviceID,
            appInstanceID: localBinding.appInstanceID,
            clientNamespace: localBinding.clientNamespace,
            tag: fixture.initiator.tag,
            displayName: nil,
            identity: identity,
            capabilities: localBinding.capabilities,
            managedRelayURLs: [fixture.relayURL],
            cachedBinding: CmxIrohBrokerBindingMetadata(binding: localBinding)
        )
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [
                TestIrohEndpoint(identity: fixture.initiator.endpointID),
            ]),
            broker: TestRevisionedClientBroker(
                binding: localBinding,
                discoveries: [rejectedRevision],
                registrationError: .connectivity
            ),
            configuration: configuration,
            pendingRevocations: CmxIrohPendingRevocationOutbox(
                secureStore: TestSecureCredentialStore()
            ),
            offlinePolicyCache: cache,
            now: { fixture.now }
        )

        await #expect(throws: CmxIrohTrustBrokerClientError.connectivity) {
            try await runtime.start()
        }
    }

    @Test
    func startupConsumesEmbeddedDiscoveryWithoutAThirdBrokerRoundTrip() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let discovery = try ClientRuntimeTestFixture.discovery(
            binding: fixture.binding,
            revision: 1
        )
        let broker = TestRevisionedClientBroker(
            binding: fixture.binding,
            discoveries: [discovery],
            embedInitialDiscovery: true
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

        #expect(await broker.registrationCount == 1)
        #expect(await broker.syncCount == 0)
        #expect(await runtime.connectivityEngine.snapshot().routeRevision == 1)
        await runtime.stop()
    }

    @Test
    func pendingRevocationInvalidatesEmbeddedRegistrationDiscovery() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let staleDiscovery = try ClientRuntimeTestFixture.discovery(
            binding: fixture.binding,
            revision: 1
        )
        let authoritativeDiscovery = try ClientRuntimeTestFixture.discovery(
            binding: fixture.binding,
            revision: 2
        )
        let pendingRevocations = fixture.pendingRevocations()
        let pending = try CmxIrohPendingRevocation(
            accountID: fixture.configuration.accountID,
            tag: "older-build",
            bindingID: "123e4567-e89b-42d3-a456-426614174099"
        )
        try await pendingRevocations.enqueue(pending)
        let broker = TestRevisionedClientBroker(
            binding: fixture.binding,
            discoveries: [authoritativeDiscovery],
            embeddedRegistrationDiscovery: staleDiscovery,
            embeddedRegistrationDiscoveryIsComplete: true,
            registrationRevision: 1
        )
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [
                TestIrohEndpoint(identity: fixture.endpointID),
            ]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: pendingRevocations,
            now: { fixture.now }
        )

        try await runtime.start()

        #expect(await broker.syncCount == 1)
        #expect(await runtime.connectivityEngine.snapshot().routeRevision == 2)
        await runtime.stop()
    }

    @Test
    func startupFetchesPaginatedDiscoveryWhenRegistrationAndSyncSnapshotsAreUnproven() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let truncatedRegistrationDiscovery = try ClientRuntimeTestFixture.discovery(
            binding: fixture.binding,
            includeBinding: false,
            revision: 1
        )
        let completeDiscovery = try ClientRuntimeTestFixture.discovery(
            binding: fixture.binding,
            revision: 1
        )
        let broker = TestRevisionedClientBroker(
            binding: fixture.binding,
            discoveries: [truncatedRegistrationDiscovery, completeDiscovery],
            embeddedRegistrationDiscovery: truncatedRegistrationDiscovery,
            connectivitySnapshotsProvenComplete: nil
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

        #expect(await broker.registrationCount == 1)
        #expect(await broker.syncCount == 1)
        #expect(await broker.discoveryCount == 1)
        #expect(await runtime.connectivityEngine.snapshot().routeRevision == 1)
        await runtime.stop()
    }

    @Test
    func cachedBindingSyncOverlapsBindAndRegistersAfterActivation() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let revisionOne = try ClientRuntimeTestFixture.discovery(
            binding: fixture.binding,
            revision: 1
        )
        let revisionTwo = try ClientRuntimeTestFixture.discovery(
            binding: fixture.binding,
            revision: 2
        )
        let configuration = CmxIrohClientRuntimeConfiguration(
            accountID: fixture.configuration.accountID,
            deviceID: fixture.configuration.deviceID,
            appInstanceID: fixture.configuration.appInstanceID,
            clientNamespace: fixture.configuration.clientNamespace,
            tag: fixture.configuration.tag,
            displayName: fixture.configuration.displayName,
            identity: fixture.configuration.identity,
            capabilities: fixture.configuration.capabilities,
            managedRelayURLs: fixture.configuration.managedRelayURLs,
            cachedBinding: CmxIrohBrokerBindingMetadata(binding: fixture.binding)
        )
        let factory = TestBlockingIrohEndpointFactory(
            endpoint: TestIrohEndpoint(identity: fixture.endpointID)
        )
        let bindStarted = await factory.bindStartedEvents()
        let broker = TestRevisionedClientBroker(
            binding: fixture.binding,
            discoveries: [revisionOne, revisionTwo],
            blockedRegistrationCount: 1
        )
        let runtime = try CmxIrohClientRuntime(
            factory: factory,
            broker: broker,
            configuration: configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { fixture.now }
        )
        let start = Task { try await runtime.start() }

        for await _ in bindStarted { break }
        await broker.waitUntilSyncCount(1)
        #expect(await broker.registrationCount == 0)

        await factory.release()
        try await start.value
        await broker.waitUntilRegistrationCount(1)

        #expect(await runtime.snapshot().state == .active)
        #expect(await runtime.liveDiscoverySnapshotGeneration() == 1)
        #expect(await runtime.connectivityEngine.snapshot().routeRevision == 1)
        #expect(await broker.syncCount == 1)

        await broker.releaseBlockedRegistration()
        await broker.waitUntilSyncCount(2)
        for _ in 0..<1_000 {
            if await runtime.liveDiscoverySnapshotGeneration() >= 2 { break }
            await Task.yield()
        }
        #expect(await runtime.liveDiscoverySnapshotGeneration() == 2)
        #expect(await runtime.connectivityEngine.snapshot().routeRevision == 2)
        await runtime.stop()
    }

    @Test
    func pushedRevisionReconcilesReadOnlyAndSkipsObsoleteHints() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let revisionOne = try ClientRuntimeTestFixture.discovery(
            binding: fixture.binding,
            revision: 1
        )
        let revisionTwo = try ClientRuntimeTestFixture.discovery(
            binding: fixture.binding,
            revision: 2
        )
        let broker = TestRevisionedClientBroker(
            binding: fixture.binding,
            discoveries: [revisionOne, revisionTwo]
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

        #expect(await broker.registrationCount == 1)
        #expect(await broker.syncCount == 1)
        #expect(
            await runtime.reconcileConnectivityRevision(2) == .refreshed
        )
        #expect(await broker.registrationCount == 1)
        #expect(await broker.syncCount == 2)
        #expect(await recorder.observedBindingCount() == 2)
        #expect(
            await runtime.connectivityEngine.snapshot().routeRevision == 2
        )

        #expect(
            await runtime.reconcileConnectivityRevision(1) == .refreshed
        )
        #expect(await broker.registrationCount == 1)
        #expect(await broker.syncCount == 2)
        await runtime.stop()
    }

    @Test
    func pushedRevisionCoalescingCannotLoseTheNewestHint() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let discoveries = try (1...3).map {
            try ClientRuntimeTestFixture.discovery(
                binding: fixture.binding,
                revision: UInt64($0)
            )
        }
        let broker = TestRevisionedClientBroker(
            binding: fixture.binding,
            discoveries: discoveries,
            blockedSyncCount: 2
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

        async let revisionTwo = runtime.reconcileConnectivityRevision(2)
        await broker.waitUntilSyncCount(2)
        async let revisionThree = runtime.reconcileConnectivityRevision(3)
        for _ in 0..<10 {
            await Task.yield()
        }
        await broker.releaseBlockedSync()

        #expect(await revisionTwo == .refreshed)
        #expect(await revisionThree == .refreshed)
        #expect(await broker.registrationCount == 1)
        #expect(await broker.syncCount == 3)
        #expect(
            await runtime.connectivityEngine.snapshot().routeRevision == 3
        )
        await runtime.stop()
    }

    @Test
    func startInstallsExactIOSBindingAndManagedRelays() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let factory = TestIrohEndpointFactory(endpoints: [endpoint])
        let broker = TestIrohClientBroker(
            binding: fixture.binding,
            discovery: fixture.discovery
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
            }
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
        // Tokenless transport: relays are configured at bind time and the
        // connect path installs no credential and mutates no relay.
        #expect(await endpoint.observedRelayProfileUpdates().isEmpty)
        #expect(await recorder.observedBindingCount() == 1)
        #expect(runtime.transportFactory.supportedKinds == [.iroh])
        await runtime.stop()
    }

    @Test
    func liveDiscoveryRefreshReturnsTrueOnlyAfterNewVerifiedSnapshot() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let broker = TestIrohClientBroker(
            binding: fixture.binding,
            discovery: fixture.discovery
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
        #expect(await broker.observedRegistrations().count == 1)
        #expect(await broker.observedDiscoveryCount() == 2)
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
            discoveryErrorsByCount: [
                2: CmxIrohTrustBrokerClientError.connectivity,
            ]
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
        let rateLimit = CmxIrohTrustBrokerClientError.rateLimited(
            code: nil,
            retryAfterSeconds: 15
        )
        let broker = TestIrohClientBroker(
            binding: fixture.binding,
            discovery: fixture.discovery,
            discoveryErrorsByCount: [2: rateLimit]
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

        #expect(
            await runtime.refreshLiveDiscoveryOutcome()
                == .failed(.policyUnavailable)
        )
        #expect(await runtime.snapshot().state == .active)
        await runtime.stop()
    }

    @Test
    func rateLimitedRegistrationStartsFromFreshAuthenticatedDiscovery() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let broker = TestIrohClientBroker(
            binding: fixture.binding,
            discovery: fixture.discovery,
            registrationError: CmxIrohTrustBrokerClientError.rateLimited(
                code: "device_registration_hour_quota",
                retryAfterSeconds: 600
            )
        )
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { fixture.now }
        )

        try await runtime.start()

        let snapshot = await runtime.snapshot()
        #expect(snapshot.state == .active)
        #expect(snapshot.endpointID == fixture.endpointID)
        #expect(snapshot.bindingID == fixture.binding.bindingID)
        #expect(await broker.observedRegistrations().count == 1)
        #expect(await broker.observedDiscoveryCount() == 1)
        #expect(await endpoint.observedCloseCallCount() == 0)
        await runtime.stop()
    }

    @Test
    func rateLimitedRegistrationDrainsPendingRevocationsBeforeDiscovery() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let pendingRevocations = fixture.pendingRevocations()
        let pending = try CmxIrohPendingRevocation(
            accountID: fixture.configuration.accountID,
            tag: "older-build",
            bindingID: "123e4567-e89b-42d3-a456-426614174099"
        )
        try await pendingRevocations.enqueue(pending)
        let broker = TestIrohClientBroker(
            binding: fixture.binding,
            discovery: fixture.discovery,
            registrationError: CmxIrohTrustBrokerClientError.rateLimited(
                code: "device_registration_hour_quota",
                retryAfterSeconds: 600
            )
        )
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [
                TestIrohEndpoint(identity: fixture.endpointID),
            ]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: pendingRevocations,
            now: { fixture.now }
        )

        try await runtime.start()

        #expect(await broker.observedRegistrations().count == 1)
        #expect(await broker.observedRevokedBindingIDs() == [pending.bindingID])
        #expect(await broker.observedDiscoveryCount() == 1)
        #expect(
            try await pendingRevocations.pending(
                accountID: fixture.configuration.accountID
            ).isEmpty
        )
        await runtime.stop()
    }

    @Test
    func rateLimitedRegistrationWithoutBindingProofDoesNotDrainOrDiscover() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let pendingRevocations = fixture.pendingRevocations()
        let pending = try CmxIrohPendingRevocation(
            accountID: fixture.configuration.accountID,
            tag: "older-build",
            bindingID: "123e4567-e89b-42d3-a456-426614174099"
        )
        try await pendingRevocations.enqueue(pending)
        let broker = TestIrohClientBroker(
            binding: fixture.binding,
            discovery: fixture.discovery,
            bindingAuthorizationAvailable: false,
            registrationError: CmxIrohTrustBrokerClientError.rateLimited(
                code: "device_registration_hour_quota",
                retryAfterSeconds: 600
            )
        )
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [
                TestIrohEndpoint(identity: fixture.endpointID),
            ]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: pendingRevocations,
            now: { fixture.now }
        )

        await #expect(throws: CmxIrohTrustBrokerClientError.rateLimited(
            code: "device_registration_hour_quota",
            retryAfterSeconds: 600
        )) {
            try await runtime.start()
        }
        #expect(await broker.observedDiscoveryCount() == 0)
        #expect(try await pendingRevocations.pending(
            accountID: fixture.configuration.accountID
        ) == [pending])
    }

    @Test
    func rateLimitedRegistrationDoesNotRevokeRetainedAuthorization() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let pendingRevocations = fixture.pendingRevocations()
        let pending = try CmxIrohPendingRevocation(
            accountID: fixture.configuration.accountID,
            tag: fixture.configuration.tag,
            bindingID: fixture.binding.bindingID
        )
        try await pendingRevocations.enqueue(pending)
        let broker = TestIrohClientBroker(
            binding: fixture.binding,
            discovery: fixture.discovery,
            registrationError: CmxIrohTrustBrokerClientError.rateLimited(
                code: "device_registration_hour_quota",
                retryAfterSeconds: 600
            )
        )
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [
                TestIrohEndpoint(identity: fixture.endpointID),
            ]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: pendingRevocations,
            now: { fixture.now }
        )

        try await runtime.start()

        #expect(await broker.observedRevokedBindingIDs().isEmpty)
        #expect(await broker.observedDiscoveryCount() == 1)
        #expect(try await pendingRevocations.pending(
            accountID: fixture.configuration.accountID
        ).isEmpty)
        await runtime.stop()
    }

    @Test
    func rateLimitedRegistrationRejectsMissingOrSubstitutedDiscoveryBinding() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let cases = [
            (
                "missing",
                try ClientRuntimeTestFixture.discovery(
                    binding: fixture.binding,
                    includeBinding: false
                )
            ),
            (
                "substituted",
                try ClientRuntimeTestFixture.discovery(
                    binding: fixture.binding,
                    overrideAppInstanceID: "123e4567-e89b-42d3-a456-426614174099"
                )
            ),
        ]

        for (name, discovery) in cases {
            let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
            let broker = TestIrohClientBroker(
                binding: fixture.binding,
                discovery: discovery,
                registrationError: CmxIrohTrustBrokerClientError.rateLimited(
                    code: "device_registration_hour_quota",
                    retryAfterSeconds: 600
                )
            )
            let runtime = try CmxIrohClientRuntime(
                factory: TestIrohEndpointFactory(endpoints: [endpoint]),
                broker: broker,
                configuration: fixture.configuration,
                pendingRevocations: fixture.pendingRevocations(),
                now: { fixture.now }
            )

            do {
                try await runtime.start()
                Issue.record("Expected \(name) local binding to fail closed")
                await runtime.stop()
            } catch {
                #expect(
                    error as? CmxIrohClientRuntimeError
                        == .localBindingMissingFromDiscovery,
                    Comment(rawValue: name)
                )
            }
            #expect(
                await endpoint.observedCloseCallCount() == 1,
                Comment(rawValue: name)
            )
            #expect(
                await broker.observedDiscoveryCount() == 1,
                Comment(rawValue: name)
            )
        }
    }

    @Test
    func rateLimitedRegistrationAndDiscoveryConnectivityNeverReadOfflineCache() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let store = TestSecureCredentialStore()
        let connectivity = CmxIrohTrustBrokerClientError.connectivity
        let broker = TestIrohClientBroker(
            binding: fixture.binding,
            discovery: fixture.discovery,
            registrationError: CmxIrohTrustBrokerClientError.rateLimited(
                code: "device_registration_hour_quota",
                retryAfterSeconds: 600
            ),
            discoveryErrorsByCount: [1: connectivity]
        )
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            offlinePolicyCache: CmxIrohClientOfflinePolicyCache(secureStore: store),
            now: { fixture.now }
        )

        await #expect(throws: connectivity) {
            try await runtime.start()
        }

        #expect(await store.readCount() == 0)
        #expect(await broker.observedDiscoveryCount() == 1)
        #expect(await endpoint.observedCloseCallCount() == 1)
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
                discovery: fixture.discovery
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
                discovery: fixture.discovery
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
            discovery: substitutedDiscovery
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
            discoveryErrorsByCount: [
                2: CmxIrohTrustBrokerClientError.connectivity,
            ]
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
        #expect(await broker.observedRegistrations().count == 1)
        #expect(await broker.observedDiscoveryCount() == 2)
        #expect(await runtime.snapshot().state == .active)
        await runtime.stop()
    }

    @Test
    func foregroundRecreatesStaleDriverWithStableIdentity() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let staleEndpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let replacementEndpoint = TestIrohEndpoint(
            identity: fixture.endpointID,
            directAddresses: ["0.0.0.0:50909"]
        )
        let factory = TestIrohEndpointFactory(
            endpoints: [staleEndpoint, replacementEndpoint]
        )
        let broker = TestIrohClientBroker(
            binding: fixture.binding,
            discovery: fixture.discovery
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
    func foregroundUnauthorizedBrokerFailurePreservesLocalPolicy() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let terminal = CmxIrohTrustBrokerClientError.rejected(
            statusCode: 401,
            code: "unauthorized"
        )
        let broker = TestIrohClientBroker(
            binding: fixture.binding,
            discovery: fixture.discovery,
            discoveryErrorsByCount: [2: terminal]
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

        try await runtime.didBecomeActive()

        #expect(await runtime.snapshot().state == .active)
        #expect(await endpoint.observedCloseCallCount() == 0)
        #expect(await offlineStore.deleteAllCount() == 0)
        #expect(await recorder.observedPolicyInvalidationCount() == 0)
        await runtime.stop()
    }

    @Test
    func foregroundConnectivityFailureKeepsLastVerifiedPolicy() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let broker = TestIrohClientBroker(
            binding: fixture.binding,
            discovery: fixture.discovery
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
            discoveryErrorsByCount: [2: failure]
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
        #expect(
            preparation.bindingAuthorization?.bindingID
                == fixture.binding.bindingID
        )
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
    func signOutAuthorizationUsesPersistedLegacyBindingNamespace() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let configuration = CmxIrohClientRuntimeConfiguration(
            accountID: fixture.configuration.accountID,
            deviceID: fixture.configuration.deviceID,
            appInstanceID: fixture.configuration.appInstanceID,
            clientNamespace: "dev.cmux.app.beta",
            tag: fixture.configuration.tag,
            displayName: fixture.configuration.displayName,
            identity: fixture.configuration.identity,
            capabilities: fixture.configuration.capabilities,
            managedRelayURLs: fixture.configuration.managedRelayURLs
        )
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: []),
            broker: TestIrohClientBroker(
                binding: fixture.binding,
                discovery: fixture.discovery
            ),
            configuration: configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { fixture.now }
        )
        await runtime.installLocalBindingForSignOutTest(fixture.binding)

        let preparation = await runtime.deactivateForSignOut()

        #expect(preparation.bindingAuthorization?.clientNamespace == "legacy")
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
                discovery: fixture.discovery
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
                discovery: fixture.discovery
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
    func pendingRevocationFailureStopsAfterAuthenticatedRegistration() async throws {
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

        #expect(await broker.observedRegistrations().count == 1)
        #expect(await broker.observedDiscoveryCount() == 0)
        #expect(await broker.observedRevokedBindingIDs() == [pending.bindingID])
        #expect(
            try await pendingRevocations.pending(
                accountID: fixture.configuration.accountID
            ) == [pending]
        )
    }

}

private actor TestRevisionedClientBroker:
    CmxIrohClientBrokerServing,
    CmxConnectivityAuthorityServing
{
    private let binding: CmxIrohBrokerBinding
    private var discoveries: [CmxIrohDiscoveryResponse]
    private let blockedSyncCount: Int?
    private let blockedRegistrationCount: Int?
    private let embeddedRegistrationDiscovery: CmxIrohDiscoveryResponse?
    private let embeddedRegistrationDiscoveryIsComplete: Bool?
    private let registrationRevision: UInt64?
    private let registrationError: CmxIrohTrustBrokerClientError?
    private let connectivitySnapshotsProvenComplete: Bool?
    private(set) var registrationCount = 0
    private(set) var discoveryCount = 0
    private(set) var syncCount = 0
    private var blockedSyncReleased = false
    private var blockedRegistrationReleased = false

    init(
        binding: CmxIrohBrokerBinding,
        discoveries: [CmxIrohDiscoveryResponse],
        blockedSyncCount: Int? = nil,
        blockedRegistrationCount: Int? = nil,
        embedInitialDiscovery: Bool = false,
        embeddedRegistrationDiscovery: CmxIrohDiscoveryResponse? = nil,
        embeddedRegistrationDiscoveryIsComplete: Bool? = nil,
        registrationRevision: UInt64? = nil,
        registrationError: CmxIrohTrustBrokerClientError? = nil,
        connectivitySnapshotsProvenComplete: Bool? = true
    ) {
        self.binding = binding
        self.discoveries = discoveries
        self.blockedSyncCount = blockedSyncCount
        self.blockedRegistrationCount = blockedRegistrationCount
        self.embeddedRegistrationDiscovery = embeddedRegistrationDiscovery
            ?? (embedInitialDiscovery ? discoveries.first : nil)
        self.embeddedRegistrationDiscoveryIsComplete = embeddedRegistrationDiscoveryIsComplete
            ?? (embedInitialDiscovery ? true : nil)
        self.registrationRevision = registrationRevision
        self.registrationError = registrationError
        self.connectivitySnapshotsProvenComplete = connectivitySnapshotsProvenComplete
    }

    func register(
        prepared _: CmxIrohPreparedRegistration,
        signer _: CmxIrohRegistrationSigner
    ) async throws -> CmxIrohRegistrationResponse {
        registrationCount += 1
        if registrationCount == blockedRegistrationCount {
            while !blockedRegistrationReleased {
                await Task.yield()
            }
        }
        if let registrationError { throw registrationError }
        return CmxIrohRegistrationResponse(
            revision: registrationRevision
                ?? embeddedRegistrationDiscovery?.revision
                ?? discoveries.first?.revision,
            binding: binding,
            relay: .unavailable,
            discovery: embeddedRegistrationDiscovery,
            discoveryComplete: embeddedRegistrationDiscoveryIsComplete
        )
    }

    func syncConnectivity(
        knownRevision: UInt64?
    ) async throws -> CmxConnectivitySyncResponse {
        syncCount += 1
        if syncCount == blockedSyncCount {
            while !blockedSyncReleased {
                await Task.yield()
            }
        }
        guard !discoveries.isEmpty else {
            throw TestIrohTransportError.unsupported
        }
        let discovery = discoveries.removeFirst()
        return CmxConnectivitySyncResponse(
            legacySnapshot: discovery,
            knownRevision: knownRevision,
            snapshotComplete: connectivitySnapshotsProvenComplete
        )
    }

    func discover() throws -> CmxIrohDiscoveryResponse {
        discoveryCount += 1
        guard let discovery = discoveries.first else {
            throw TestIrohTransportError.unsupported
        }
        return discovery
    }

    func issuePairGrant(
        initiatorBindingID _: String,
        acceptorBindingID _: String
    ) throws -> CmxIrohPairGrantResponse {
        throw TestIrohTransportError.unsupported
    }

    func revoke(bindingID _: String) {}

    func revokeStale(bindingID _: String) {}

    func forgetMac(bindingID _: String) {}

    func waitUntilSyncCount(_ minimum: Int) async {
        while syncCount < minimum {
            await Task.yield()
        }
    }

    func waitUntilRegistrationCount(_ minimum: Int) async {
        while registrationCount < minimum {
            await Task.yield()
        }
    }

    func releaseBlockedSync() {
        blockedSyncReleased = true
    }

    func releaseBlockedRegistration() {
        blockedRegistrationReleased = true
    }

}

private actor TestSubstitutedAddressEndpoint: CmxIrohEndpoint {
    private let peerIdentity: CmxIrohPeerIdentity
    private let addressIdentity: CmxIrohPeerIdentity

    init(
        identity: CmxIrohPeerIdentity,
        addressIdentity: CmxIrohPeerIdentity
    ) {
        peerIdentity = identity
        self.addressIdentity = addressIdentity
    }

    func identity() -> CmxIrohPeerIdentity { peerIdentity }

    func address() -> CmxIrohEndpointAddress {
        CmxIrohEndpointAddress(identity: addressIdentity, pathHints: [])
    }

    func localDirectAddresses() -> [String] { [] }

    func connect(
        to _: CmxIrohEndpointAddress,
        alpn _: Data
    ) async throws -> any CmxIrohConnection {
        throw TestIrohTransportError.unsupported
    }

    func accept() async throws -> (any CmxIrohConnection)? { nil }

    func replaceRelayProfile(_: CmxIrohEndpointRelayProfile) {}

    func healthEvents() -> AsyncStream<CmxIrohEndpointHealthEvent> {
        AsyncStream { $0.finish() }
    }

    func isHealthy() -> Bool { true }

    func close() {}
}
