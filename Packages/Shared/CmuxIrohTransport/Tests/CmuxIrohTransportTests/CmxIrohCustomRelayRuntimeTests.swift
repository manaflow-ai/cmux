import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohCustomRelayRuntimeTests {
    @Test
    func clientOverrideSkipsManagedTokenIssuance() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let custom = try CmxIrohCustomRelayProfile(
            relays: [CmxIrohCustomRelay(url: "https://private.example.net:8443/")]
        )
        let profile = CmxIrohEndpointRelayProfile(customProfile: custom)
        let configuration = CmxIrohClientRuntimeConfiguration(
            accountID: fixture.configuration.accountID,
            deviceID: fixture.configuration.deviceID,
            appInstanceID: fixture.configuration.appInstanceID,
            tag: fixture.configuration.tag,
            displayName: fixture.configuration.displayName,
            identity: fixture.identity,
            capabilities: fixture.configuration.capabilities,
            managedRelayURLs: fixture.configuration.managedRelayURLs,
            endpointRelayProfile: profile
        )
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
            configuration: configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { fixture.now }
        )

        try await runtime.start()

        #expect(await runtime.snapshot().state == .active)
        #expect(await broker.observedRelayIssueCount() == 0)
        #expect(await endpoint.observedRelayUpdates().isEmpty)
        #expect(await factory.observedConfigurations().first?.relayProfile == profile)
        await runtime.stop()
    }

    @Test
    func hostOverrideSkipsManagedTokenIssuance() async throws {
        let fixture = try HostRuntimeFixture()
        let custom = try CmxIrohCustomRelayProfile(
            relays: [CmxIrohCustomRelay(url: "https://private.example.net:8443/")]
        )
        let profile = CmxIrohEndpointRelayProfile(customProfile: custom)
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let factory = TestIrohEndpointFactory(endpoints: [endpoint])
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery
        )
        let runtime = CmxIrohHostRuntime(
            factory: factory,
            broker: broker,
            configuration: fixture.configuration(endpointRelayProfile: profile),
            pendingRevocations: fixture.pendingRevocations(),
            handleTransport: { session, _ in await session.close() }
        )

        try await runtime.start()

        #expect(await runtime.snapshot().state == .active)
        #expect(await broker.observedRelayIssueCount() == 0)
        #expect(await factory.observedConfigurations().first?.relayProfile == profile)
        await runtime.stop()
    }
}
