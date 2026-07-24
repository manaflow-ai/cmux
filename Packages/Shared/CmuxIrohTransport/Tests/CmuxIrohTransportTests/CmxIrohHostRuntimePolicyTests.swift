import CMUXMobileCore
import CryptoKit
import Foundation
import Testing

@testable import CmuxIrohTransport

extension CmxIrohHostRuntimeTests {
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
        await deactivations.waitForCount(1)

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
    func networkChangeDuringActiveRefreshRequestsAnotherRegistration() async throws {
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

        await endpoint.emit(.networkChanged)
        await broker.waitForRegistrationCount(2)
        await endpoint.emit(.networkChanged)
        #expect(await refreshes.waitForCount(2, timeout: .seconds(1)))
        await gate.open()

        let registeredAgain = await broker.waitForRegistrationCount(
            3,
            timeout: .seconds(1)
        )
        #expect(registeredAgain)
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
        .rejected(statusCode: 400, code: "invalid_request"),
        .invalidResponse,
    ])
    func terminalBrokerFailureNeverUsesCachedPolicy(
        _ failure: CmxIrohTrustBrokerClientError
    ) async throws {
        let fixture = try HostRuntimeFixture()
        let cachedFixture = try fixture.cachedPolicyFixture()
        let now = cachedFixture.now
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
            now: { now },
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
        let now = cachedFixture.now
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
            now: { now },
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
    func confirmedOnlineBindingChangePreventsDiscoveryConnectivityFallback() async throws {
        let fixture = try HostRuntimeFixture()
        let cachedFixture = try fixture.cachedPolicyFixture()
        let now = cachedFixture.now
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
            now: { now },
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
        let now = cachedFixture.now
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
            now: { now },
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

        await #expect(throws: CmxIrohHostRuntimeError.invalidLocalBinding) {
            try await runtime.start()
        }

        #expect(await endpoint.observedCloseCallCount() == 1)
        #expect(await runtime.snapshot().state == .failed)
    }
}
