import CMUXMobileCore
import CryptoKit
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohHostRuntimeTests {
    @Test
    func pendingRevocationFailureBlocksHostRegistrationAndCachedFallback() async throws {
        let fixture = try HostRuntimeFixture()
        let pendingRevocations = CmxIrohPendingRevocationOutbox(
            secureStore: TestSecureCredentialStore()
        )
        let pending = try CmxIrohPendingRevocation(
            accountID: fixture.configuration.accountID,
            tag: "older-build",
            bindingID: "123e4567-e89b-42d3-a456-426614174099"
        )
        try await pendingRevocations.enqueue(pending)
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            revokeError: .connectivity
        )
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(
                endpoints: [TestIrohEndpoint(identity: fixture.endpointID)]
            ),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: pendingRevocations,
            handleTransport: { session, _ in await session.close() }
        )

        await #expect(throws: CmxIrohTrustBrokerClientError.connectivity) {
            try await runtime.start()
        }

        #expect(await broker.observedRegistrationCount() == 0)
        #expect(await broker.observedRevokedBindingIDs() == [pending.bindingID])
        #expect(
            try await pendingRevocations.pending(
                accountID: fixture.configuration.accountID
            ) == [pending]
        )
    }

    @Test
    func startBindsExactRegisteredIdentityAndStopClosesIt() async throws {
        let fixture = try HostRuntimeFixture()
        let endpoint = TestIrohEndpoint(
            identity: fixture.endpointID,
            directAddresses: ["192.168.1.10:50906"]
        )
        let factory = TestIrohEndpointFactory(endpoints: [endpoint])
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery
        )
        let deactivations = HostRuntimeDeactivationRecorder()
        let lanPolicies = HostRuntimeLANPolicyRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: factory,
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            handleTransport: { session, _ in await session.close() },
            handleDeactivation: { bindingID in
                await deactivations.record(bindingID)
            },
            handleLANPolicy: { context, directAddresses in
                await lanPolicies.record(
                    context: context,
                    directAddresses: await directAddresses()
                )
            }
        )

        try await runtime.start()

        let snapshot = await runtime.snapshot()
        #expect(snapshot.state == .active)
        #expect(snapshot.endpointID == fixture.endpointID)
        #expect(snapshot.bindingID == fixture.binding.bindingID)
        #expect(await broker.observedRegistrationCount() == 1)
        let configurations = await factory.observedConfigurations()
        #expect(configurations.count == 1)
        #expect(configurations.first?.secretKey == fixture.identity.secretKey)
        #expect(configurations.first?.bindPolicy == .ephemeral)
        #expect(configurations.first?.managedRelayURLs == fixture.managedRelays)
        let lan = try #require(await runtime.lanAdvertisementContext())
        #expect(lan.binding == CmxIrohBrokerBindingMetadata(binding: fixture.binding))
        #expect(lan.rendezvous == fixture.discovery.lanRendezvous)
        #expect(await runtime.localDirectAddresses() == ["192.168.1.10:50906"])
        #expect(await lanPolicies.contexts() == [lan])
        #expect(await lanPolicies.addresses() == [["192.168.1.10:50906"]])

        await runtime.stop()

        #expect(await endpoint.observedCloseCallCount() == 1)
        #expect(await deactivations.values() == [fixture.binding.bindingID])
        #expect(await runtime.snapshot().state == .inactive)
        #expect(await runtime.lanAdvertisementContext() == nil)
    }

    @Test
    func suspendedSignOutPersistenceStopsPendingAdmissionAndBlocksRestart() async throws {
        let fixture = try HostRuntimeFixture()
        let endpoint = HostRuntimeAcceptingEndpoint(identity: fixture.endpointID)
        let store = TestControllableSecureCredentialStore()
        let pendingRevocations = CmxIrohPendingRevocationOutbox(secureStore: store)
        let ordering = HostRuntimeSignOutOrderingRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: TestIrohHostBroker(
                registrationBinding: fixture.binding,
                discovery: fixture.discovery
            ),
            configuration: fixture.configuration,
            pendingRevocations: pendingRevocations,
            handleTransport: { session, _ in await session.close() },
            handleDeactivation: { bindingID in
                let queued = try? await pendingRevocations.pending(
                    accountID: fixture.configuration.accountID
                ).contains(where: { $0.bindingID == bindingID })
                await ordering.record(
                    endpointClosed: await endpoint.observedCloseCallCount() == 1,
                    revocationQueued: queued == true
                )
            }
        )
        try await runtime.start()

        let blockedReceive = TestBlockingIrohReceiveStream(buffer: Data())
        var blockedEvents = await blockedReceive.blockedEvents().makeAsyncIterator()
        let connection = TestIrohConnection(
            remoteIdentity: try CmxIrohPeerIdentity(
                endpointID: String(repeating: "b", count: 64)
            ),
            bidirectionalStreams: [
                CmxIrohBidirectionalStream(
                    receiveStream: blockedReceive,
                    sendStream: TestIrohSendStream()
                ),
            ]
        )
        await endpoint.enqueue(connection)
        _ = await blockedEvents.next()
        await store.suspendNextWrite()

        let signOut = Task { await runtime.deactivateForSignOut() }
        await store.waitUntilWriteIsSuspended()
        await connection.waitUntilClosed()

        let signingOut = await runtime.snapshot()
        #expect(signingOut.state == .signingOut)
        #expect(signingOut.bindingID == fixture.binding.bindingID)
        #expect(await connection.observedCloseCallCount() > 0)
        await #expect(throws: CmxIrohHostRuntimeError.alreadyActive) {
            try await runtime.start()
        }

        await store.resumeSuspendedWrite()
        let preparation = await signOut.value
        #expect(preparation.wasPersisted)
        #expect(await ordering.values() == ["true:true"])
        #expect(await runtime.snapshot().state == .inactive)
    }

    @Test
    func failedSignOutPersistenceClosesHostAndQuarantinesLocalState() async throws {
        let fixture = try HostRuntimeFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let store = TestControllableSecureCredentialStore()
        let pendingRevocations = CmxIrohPendingRevocationOutbox(secureStore: store)
        let deactivations = HostRuntimeDeactivationRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: TestIrohHostBroker(
                registrationBinding: fixture.binding,
                discovery: fixture.discovery
            ),
            configuration: fixture.configuration,
            pendingRevocations: pendingRevocations,
            handleTransport: { session, _ in await session.close() },
            handleDeactivation: { bindingID in
                await deactivations.record(bindingID)
            }
        )
        try await runtime.start()
        await store.failNextWrite()

        let preparation = await runtime.deactivateForSignOut()

        #expect(preparation.bindingID == fixture.binding.bindingID)
        #expect(!preparation.wasPersisted)
        #expect(await endpoint.observedCloseCallCount() == 1)
        #expect(await deactivations.values() == [fixture.binding.bindingID])
        let quarantined = await runtime.snapshot()
        #expect(quarantined.state == .quarantined)
        #expect(quarantined.endpointID == nil)
        #expect(quarantined.bindingID == fixture.binding.bindingID)
        #expect(await runtime.lanAdvertisementContext() == nil)
        await #expect(throws: CmxIrohHostRuntimeError.alreadyActive) {
            try await runtime.start()
        }

        let retried = await runtime.deactivateForSignOut()
        #expect(retried.wasPersisted)
        #expect(await deactivations.values() == [fixture.binding.bindingID])
        #expect(await runtime.snapshot().state == .inactive)
    }

    @Test
    func requiredBindPolicyIsForwardedToTheEndpointGeneration() async throws {
        let fixture = try HostRuntimeFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let factory = TestIrohEndpointFactory(endpoints: [endpoint])
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery
        )
        let bindAddress = try CmxIrohBindAddress(
            ipAddress: "127.0.0.1",
            port: 4_444
        )
        let runtime = CmxIrohHostRuntime(
            factory: factory,
            broker: broker,
            configuration: fixture.configuration(
                bindPolicy: .required(bindAddress)
            ),
            pendingRevocations: fixture.pendingRevocations(),
            handleTransport: { session, _ in await session.close() }
        )

        try await runtime.start()

        #expect(
            await factory.observedConfigurations().first?.bindPolicy
                == .required(bindAddress)
        )
        await runtime.stop()
    }

    @Test
    func connectivityFailureUsesVerifiedCacheOnlyAfterOnlineAttempt() async throws {
        let fixture = try HostRuntimeFixture()
        let cachedFixture = try fixture.cachedPolicyFixture()
        let cachedPolicy = try cachedFixture.policy()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let factory = TestIrohEndpointFactory(endpoints: [endpoint])
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            registrationError: .connectivity
        )
        let bindings = HostRuntimeBindingRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: factory,
            broker: broker,
            configuration: fixture.configuration(cachedHostPolicy: cachedPolicy),
            pendingRevocations: fixture.pendingRevocations(),
            now: { cachedFixture.now },
            handleTransport: { session, _ in await session.close() },
            handleBinding: { _, _, _ in await bindings.record() }
        )

        try await runtime.start()

        #expect(await broker.observedRegistrationCount() == 1)
        #expect(await runtime.snapshot().bindingID == cachedPolicy.binding.bindingID)
        #expect(await runtime.lanAdvertisementContext()?.rendezvous == cachedPolicy.lanRendezvous)
        #expect(await bindings.count() == 0)
        await runtime.stop()
    }

    @Test
    func endpointNetworkChangeRequestsImmediateLANRefresh() async throws {
        let fixture = try HostRuntimeFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let recorder = HostRuntimeLANRefreshRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: TestIrohHostBroker(
                registrationBinding: fixture.binding,
                discovery: fixture.discovery
            ),
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            handleTransport: { session, _ in await session.close() },
            handleLANRefresh: { await recorder.record() }
        )
        try await runtime.start()

        await endpoint.emit(.networkChanged)
        #expect(await recorder.waitForRefresh(timeout: .seconds(1)))

        #expect(await recorder.count() == 1)
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
    func unavailableRegistrationRefreshPreservesActiveEndpoint(
        _ failure: CmxIrohTrustBrokerClientError
    ) async throws {
        let fixture = try HostRuntimeFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            subsequentRegistrationErrors: [failure]
        )
        let deactivations = HostRuntimeDeactivationRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            handleTransport: { session, _ in await session.close() },
            handleDeactivation: { bindingID in
                await deactivations.record(bindingID)
            }
        )
        try await runtime.start()

        await endpoint.emit(.networkChanged)
        await broker.waitForRegistrationCount(2)
        // Give the runtime actor a bounded window to apply the refresh result.
        try await ContinuousClock().sleep(for: .milliseconds(50))

        #expect(await runtime.snapshot().state == .active)
        #expect(await endpoint.observedCloseCallCount() == 0)
        #expect(await deactivations.values().isEmpty)
        await runtime.stop()
    }

    @Test
    func unauthorizedRegistrationRefreshDeactivatesActiveEndpoint() async throws {
        let fixture = try HostRuntimeFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            subsequentRegistrationErrors: [
                .rejected(statusCode: 401, code: "unauthorized"),
            ]
        )
        let deactivations = HostRuntimeDeactivationRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            handleTransport: { session, _ in await session.close() },
            handleDeactivation: { bindingID in
                await deactivations.record(bindingID)
            }
        )
        try await runtime.start()

        await endpoint.emit(.networkChanged)
        await broker.waitForRegistrationCount(2)
        // Give the runtime actor a bounded window to finish fail-closed teardown.
        try await ContinuousClock().sleep(for: .milliseconds(50))

        #expect(await runtime.snapshot().state == .failed)
        #expect(await endpoint.observedCloseCallCount() == 1)
        #expect(await deactivations.values() == [fixture.binding.bindingID])
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
        await endpoint.emit(.networkChanged)
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
        .rejected(statusCode: 503, code: "unavailable"),
        .invalidResponse,
    ])
    func terminalBrokerFailureNeverUsesCachedPolicy(
        _ failure: CmxIrohTrustBrokerClientError
    ) async throws {
        let fixture = try HostRuntimeFixture()
        let cachedFixture = try fixture.cachedPolicyFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let factory = TestIrohEndpointFactory(endpoints: [endpoint])
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            registrationError: failure
        )
        let runtime = CmxIrohHostRuntime(
            factory: factory,
            broker: broker,
            configuration: fixture.configuration(
                cachedHostPolicy: try cachedFixture.policy()
            ),
            pendingRevocations: fixture.pendingRevocations(),
            now: { cachedFixture.now },
            handleTransport: { session, _ in await session.close() }
        )

        do {
            try await runtime.start()
            Issue.record("Expected terminal broker failure")
        } catch let error as CmxIrohTrustBrokerClientError {
            #expect(error == failure)
        }

        #expect(await endpoint.observedCloseCallCount() == 1)
        #expect(await runtime.snapshot().state == .failed)
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
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
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
            now: { cachedFixture.now },
            handleTransport: { session, _ in await session.close() },
            handleBinding: { _, _, _ in await bindings.record() }
        )

        try await runtime.start()

        #expect(await runtime.snapshot().bindingID == fixture.binding.bindingID)
        #expect(await bindings.count() == 1)
        await runtime.stop()
    }

    @Test
    func forgedCachedPolicyFailsAfterConnectivityFailure() async throws {
        let fixture = try HostRuntimeFixture()
        let cachedFixture = try fixture.cachedPolicyFixture()
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
            now: { cachedFixture.now },
            handleTransport: { session, _ in await session.close() }
        )

        await #expect(throws: CmxIrohGrantVerifierError.invalidSignature) {
            try await runtime.start()
        }

        #expect(await endpoint.observedCloseCallCount() == 1)
        #expect(await runtime.snapshot().state == .failed)
    }

    @Test
    func confirmedOnlineBindingChangePreventsDiscoveryConnectivityFallback() async throws {
        let fixture = try HostRuntimeFixture()
        let cachedFixture = try fixture.cachedPolicyFixture()
        let changedBinding = try HostRuntimeFixture.binding(
            endpointID: fixture.endpointID.endpointID,
            bindingID: "123e4567-e89b-42d3-a456-426614174099"
        )
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let factory = TestIrohEndpointFactory(endpoints: [endpoint])
        let broker = TestIrohHostBroker(
            registrationBinding: changedBinding,
            discovery: fixture.discovery,
            discoveryError: .connectivity
        )
        let runtime = CmxIrohHostRuntime(
            factory: factory,
            broker: broker,
            configuration: fixture.configuration(
                cachedHostPolicy: try cachedFixture.policy()
            ),
            pendingRevocations: fixture.pendingRevocations(),
            now: { cachedFixture.now },
            handleTransport: { session, _ in await session.close() }
        )

        await #expect(throws: CmxIrohHostRuntimeError.invalidLocalBinding) {
            try await runtime.start()
        }

        #expect(await endpoint.observedCloseCallCount() == 1)
    }

    @Test
    func routeContractMismatchNeverUsesCachedPolicy() async throws {
        let fixture = try HostRuntimeFixture()
        let cachedFixture = try fixture.cachedPolicyFixture()
        let mismatchedDiscovery = try HostRuntimeFixture.discovery(
            binding: fixture.binding,
            relays: Array(fixture.managedRelays),
            routeContractVersion: 2
        )
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
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
            now: { cachedFixture.now },
            handleTransport: { session, _ in await session.close() }
        )

        await #expect(throws: CmxIrohHostRuntimeError.routeContractMismatch) {
            try await runtime.start()
        }

        #expect(await endpoint.observedCloseCallCount() == 1)
    }

    @Test
    func discoverySubstitutionFailsClosedAndClosesEndpoint() async throws {
        let fixture = try HostRuntimeFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
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
        let runtime = CmxIrohHostRuntime(
            factory: factory,
            broker: broker,
            configuration: fixture.configuration(
                cachedHostPolicy: try cachedFixture.policy()
            ),
            pendingRevocations: fixture.pendingRevocations(),
            now: { cachedFixture.now },
            handleTransport: { session, _ in await session.close() }
        )

        await #expect(throws: CmxIrohHostRuntimeError.invalidLocalBinding) {
            try await runtime.start()
        }

        #expect(await endpoint.observedCloseCallCount() == 1)
        #expect(await runtime.snapshot().state == .failed)
    }
}

private struct HostRuntimeFixture {
    let identity: CmxIrohIdentityMaterial
    let endpointID: CmxIrohPeerIdentity
    let binding: CmxIrohBrokerBinding
    let discovery: CmxIrohDiscoveryResponse
    let managedRelays: Set<String>
    let configuration: CmxIrohHostRuntimeConfiguration

    init() throws {
        let secret = Data(repeating: 0x31, count: 32)
        identity = try CmxIrohIdentityMaterial(
            secretKey: CmxIrohSecretKey(bytes: secret),
            generation: 4
        )
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: secret)
        endpointID = try CmxIrohPeerIdentity(
            endpointID: privateKey.publicKey.rawRepresentation
                .map { String(format: "%02x", $0) }
                .joined()
        )
        managedRelays = Set(Self.relayURLs)
        binding = try Self.binding(endpointID: endpointID.endpointID)
        discovery = try Self.discovery(
            binding: binding,
            relays: Self.relayURLs
        )
        configuration = CmxIrohHostRuntimeConfiguration(
            accountID: "account-a",
            deviceID: binding.deviceID,
            appInstanceID: binding.appInstanceID,
            tag: binding.tag,
            displayName: binding.displayName,
            identity: identity,
            pairingEnabled: binding.pairingEnabled,
            capabilities: binding.capabilities,
            managedRelayURLs: managedRelays
        )
    }

    func configuration(
        cachedHostPolicy: CmxIrohCachedHostPolicy? = nil,
        bindPolicy: CmxIrohEndpointBindPolicy = .ephemeral
    ) -> CmxIrohHostRuntimeConfiguration {
        CmxIrohHostRuntimeConfiguration(
            accountID: configuration.accountID,
            deviceID: binding.deviceID,
            appInstanceID: binding.appInstanceID,
            tag: binding.tag,
            displayName: binding.displayName,
            identity: identity,
            pairingEnabled: binding.pairingEnabled,
            capabilities: binding.capabilities,
            bindPolicy: bindPolicy,
            managedRelayURLs: managedRelays,
            cachedHostPolicy: cachedHostPolicy
        )
    }

    func cachedPolicyFixture(
        binding: CmxIrohBrokerBindingMetadata? = nil
    ) throws -> HostPolicyCacheTestFixture {
        try HostPolicyCacheTestFixture(
            binding: binding ?? CmxIrohBrokerBindingMetadata(binding: self.binding),
            pairingEnabled: self.binding.pairingEnabled,
            capabilities: self.binding.capabilities
        )
    }

    func pendingRevocations() -> CmxIrohPendingRevocationOutbox {
        CmxIrohPendingRevocationOutbox(
            secureStore: TestSecureCredentialStore()
        )
    }

    static let relayURLs = [
        "https://aps1-1.relay.lawrence.cmux.iroh.link/",
        "https://euc1-1.relay.lawrence.cmux.iroh.link/",
        "https://use1-1.relay.lawrence.cmux.iroh.link/",
        "https://usw1-1.relay.lawrence.cmux.iroh.link/",
    ]

    static func binding(
        endpointID: String,
        bindingID: String = "123e4567-e89b-42d3-a456-426614174010"
    ) throws -> CmxIrohBrokerBinding {
        try JSONDecoder().decode(
            CmxIrohBrokerBinding.self,
            from: bindingJSON(endpointID: endpointID, bindingID: bindingID)
        )
    }

    static func discovery(
        binding: CmxIrohBrokerBinding,
        relays: [String],
        overrideDeviceID: String? = nil,
        routeContractVersion: Int = 1,
        lanGeneration: Int = 1
    ) throws -> CmxIrohDiscoveryResponse {
        let bindingObject = try JSONSerialization.jsonObject(
            with: bindingJSON(
                endpointID: binding.endpointID.endpointID,
                bindingID: binding.bindingID,
                deviceID: overrideDeviceID ?? binding.deviceID
            )
        )
        let object: [String: Any] = [
            "route_contract_version": routeContractVersion,
            "bindings": [bindingObject],
            "relay_fleet": relays,
            "lan_rendezvous": [
                "generation": lanGeneration,
                "key": Data(repeating: 0, count: 32).base64URL,
            ],
            "grant_verification_keys": [
                "version": 1,
                "current_kid": "test-key",
                "keys": [[
                    "kid": "test-key",
                    "alg": "EdDSA",
                    "spki_der_base64": "AA==",
                ]],
            ],
        ]
        return try JSONDecoder().decode(
            CmxIrohDiscoveryResponse.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private static func bindingJSON(
        endpointID: String,
        bindingID: String = "123e4567-e89b-42d3-a456-426614174010",
        deviceID: String = "123e4567-e89b-42d3-a456-426614174011"
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "binding_id": bindingID,
            "device_id": deviceID,
            "app_instance_id": "123e4567-e89b-42d3-a456-426614174012",
            "tag": "cmux-ios-v0",
            "platform": "mac",
            "display_name": "Test Mac",
            "endpoint_id": endpointID,
            "identity_generation": 4,
            "pairing_enabled": true,
            "capabilities": ["rpc", "multistream"],
            "path_hints": [],
            "last_seen_at": "2026-07-09T12:00:00.000Z",
        ])
    }
}

private actor TestIrohHostBroker: CmxIrohHostBrokerServing {
    private let registrationBinding: CmxIrohBrokerBinding
    private var discoveryResponses: [CmxIrohDiscoveryResponse]
    private let registrationError: CmxIrohTrustBrokerClientError?
    private let discoveryError: CmxIrohTrustBrokerClientError?
    private let revokeError: CmxIrohTrustBrokerClientError?
    private let registrationHook: (@Sendable () async -> Bool)?
    private var subsequentRegistrationErrors: [CmxIrohTrustBrokerClientError]
    private var registrationCount = 0
    private var registrationHookResult: Bool?
    private var revokedBindingIDs: [String] = []
    private var registrationCountWaiters: [
        (minimum: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    init(
        registrationBinding: CmxIrohBrokerBinding,
        discovery: CmxIrohDiscoveryResponse,
        subsequentDiscoveries: [CmxIrohDiscoveryResponse] = [],
        registrationError: CmxIrohTrustBrokerClientError? = nil,
        discoveryError: CmxIrohTrustBrokerClientError? = nil,
        revokeError: CmxIrohTrustBrokerClientError? = nil,
        registrationHook: (@Sendable () async -> Bool)? = nil,
        subsequentRegistrationErrors: [CmxIrohTrustBrokerClientError] = []
    ) {
        self.registrationBinding = registrationBinding
        discoveryResponses = [discovery] + subsequentDiscoveries
        self.registrationError = registrationError
        self.discoveryError = discoveryError
        self.revokeError = revokeError
        self.registrationHook = registrationHook
        self.subsequentRegistrationErrors = subsequentRegistrationErrors
    }

    func register(
        prepared _: CmxIrohPreparedRegistration,
        signer _: CmxIrohRegistrationSigner
    ) async throws -> CmxIrohRegistrationResponse {
        registrationCount += 1
        let ready = registrationCountWaiters.filter {
            registrationCount >= $0.minimum
        }
        registrationCountWaiters.removeAll {
            registrationCount >= $0.minimum
        }
        for waiter in ready { waiter.continuation.resume() }
        if registrationCount == 1, let registrationError {
            throw registrationError
        }
        if registrationCount > 1, !subsequentRegistrationErrors.isEmpty {
            throw subsequentRegistrationErrors.removeFirst()
        }
        if let registrationHook {
            registrationHookResult = await registrationHook()
        }
        return CmxIrohRegistrationResponse(
            binding: registrationBinding,
            relay: .unavailable
        )
    }

    func discover() throws -> CmxIrohDiscoveryResponse {
        if let discoveryError { throw discoveryError }
        guard discoveryResponses.count > 1 else {
            return discoveryResponses[0]
        }
        return discoveryResponses.removeFirst()
    }

    func issueEndpointAttestation(
        bindingID _: String
    ) throws -> CmxIrohEndpointAttestationResponse {
        throw TestIrohTransportError.unsupported
    }

    func issueRelayToken(bindingID _: String) -> CmxIrohRelayTokenResponse {
        CmxIrohRelayTokenResponse(
            token: "testrelaytoken",
            expiresAt: "2027-07-10T12:00:00.000Z",
            refreshAfter: "2027-07-10T11:00:00.000Z",
            relayFleet: HostRuntimeFixture.relayURLs
        )
    }

    func revoke(bindingID: String) throws {
        revokedBindingIDs.append(bindingID)
        if let revokeError { throw revokeError }
    }

    func observedRegistrationCount() -> Int { registrationCount }

    func waitForRegistrationCount(_ minimum: Int) async {
        if registrationCount >= minimum { return }
        await withCheckedContinuation { continuation in
            registrationCountWaiters.append((minimum, continuation))
        }
    }

    func observedRegistrationHookResult() -> Bool? { registrationHookResult }
    func observedRevokedBindingIDs() -> [String] { revokedBindingIDs }
}

private actor HostRuntimeBindingRecorder {
    private var recordedCount = 0

    func record() { recordedCount += 1 }
    func count() -> Int { recordedCount }
}

private actor HostRuntimeDeactivationRecorder {
    private var recorded: [String?] = []

    func record(_ bindingID: String?) { recorded.append(bindingID) }
    func values() -> [String?] { recorded }
}

private actor HostRuntimeLANRefreshRecorder {
    private var recordedCount = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func record() {
        recordedCount += 1
        let pending = waiters.values
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending { waiter.resume() }
    }

    func waitForRefresh(timeout: Duration) async -> Bool {
        if recordedCount > 0 { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.waitForRefresh()
                return true
            }
            group.addTask {
                do {
                    // A bounded test deadline prevents a missing lifecycle signal from hanging CI.
                    try await ContinuousClock().sleep(for: timeout)
                } catch {}
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    func count() -> Int { recordedCount }

    private func waitForRefresh() async {
        if recordedCount > 0 { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}

private actor HostRuntimeLANPolicyRecorder {
    private var recordedContexts: [CmxIrohHostLANAdvertisementContext] = []
    private var recordedAddresses: [[String]] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record(
        context: CmxIrohHostLANAdvertisementContext,
        directAddresses: [String]
    ) {
        recordedContexts.append(context)
        recordedAddresses.append(directAddresses)
        let ready = waiters.filter { recordedContexts.count >= $0.count }
        waiters.removeAll { recordedContexts.count >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
    }

    func contexts() -> [CmxIrohHostLANAdvertisementContext] { recordedContexts }
    func addresses() -> [[String]] { recordedAddresses }

    func waitForCount(_ count: Int) async {
        if recordedContexts.count >= count { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }
}

private actor HostRuntimeSignOutOrderingRecorder {
    private var recorded: [String] = []

    func record(endpointClosed: Bool, revocationQueued: Bool) {
        recorded.append("\(endpointClosed):\(revocationQueued)")
    }

    func values() -> [String] { recorded }
}

private actor HostRuntimeAcceptingEndpoint: CmxIrohEndpoint {
    private let peerIdentity: CmxIrohPeerIdentity
    private var connections: [any CmxIrohConnection] = []
    private var waiters: [
        UUID: CheckedContinuation<(any CmxIrohConnection)?, Never>
    ] = [:]
    private let health: AsyncStream<CmxIrohEndpointHealthEvent>
    private let healthContinuation: AsyncStream<CmxIrohEndpointHealthEvent>.Continuation
    private var closed = false
    private var closeCallCount = 0

    init(identity: CmxIrohPeerIdentity) {
        peerIdentity = identity
        let stream = AsyncStream<CmxIrohEndpointHealthEvent>.makeStream()
        health = stream.stream
        healthContinuation = stream.continuation
    }

    func identity() -> CmxIrohPeerIdentity { peerIdentity }

    func address() -> CmxIrohEndpointAddress {
        CmxIrohEndpointAddress(identity: peerIdentity, pathHints: [])
    }

    func connect(
        to _: CmxIrohEndpointAddress,
        alpn _: Data
    ) async throws -> any CmxIrohConnection {
        throw TestIrohTransportError.unsupported
    }

    func accept() async throws -> (any CmxIrohConnection)? {
        try Task.checkCancellation()
        if !connections.isEmpty { return connections.removeFirst() }
        guard !closed else { return nil }
        let id = UUID()
        let connection = await withTaskCancellationHandler {
            await withCheckedContinuation { waiters[id] = $0 }
        } onCancel: {
            Task { await self.cancelAccept(id) }
        }
        try Task.checkCancellation()
        return connection
    }

    func replaceRelays(_: [CmxIrohRelayConfiguration]) {}
    func healthEvents() -> AsyncStream<CmxIrohEndpointHealthEvent> { health }
    func isHealthy() -> Bool { true }

    func close() {
        closed = true
        closeCallCount += 1
        let pending = waiters.values
        waiters.removeAll()
        for continuation in pending { continuation.resume(returning: nil) }
        healthContinuation.finish()
    }

    func enqueue(_ connection: any CmxIrohConnection) {
        if let id = waiters.keys.first,
           let continuation = waiters.removeValue(forKey: id) {
            continuation.resume(returning: connection)
        } else {
            connections.append(connection)
        }
    }

    func observedCloseCallCount() -> Int { closeCallCount }

    private func cancelAccept(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: nil)
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
