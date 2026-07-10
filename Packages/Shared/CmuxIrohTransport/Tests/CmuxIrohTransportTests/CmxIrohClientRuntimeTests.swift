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
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            now: { fixture.now },
            handleLocalDeactivation: {
                await recorder.recordLocalWipe(
                    endpointWasClosed: await endpoint.observedCloseCallCount() == 1
                )
            }
        )
        try await runtime.start()

        let preparation = await runtime.deactivateForSignOut()

        #expect(preparation.bindingID == fixture.binding.bindingID)
        #expect(await recorder.observedLocalWipes() == [true])
        #expect(await runtime.snapshot().state == .inactive)
        await #expect(throws: TestIrohTransportError.unsupported) {
            try await preparation.revoke(using: broker)
        }
        #expect(await broker.observedRevokedBindingIDs() == [fixture.binding.bindingID])
        #expect(await recorder.observedLocalWipes() == [true])
        #expect(await runtime.snapshot().state == .inactive)
    }
}
