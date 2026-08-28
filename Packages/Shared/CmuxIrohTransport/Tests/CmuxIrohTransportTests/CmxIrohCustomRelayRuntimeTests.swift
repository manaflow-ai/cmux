import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohCustomRelayRuntimeTests {
    @Test
    func clientManagedPolicyRefreshMutatesEndpointExactlyOnce() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: TestIrohClientBroker(
                binding: fixture.binding,
                discovery: fixture.discovery
            ),
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { fixture.now }
        )
        try await runtime.start()
        let initialProfileUpdates = await endpoint.observedRelayProfileUpdates().count

        try await runtime.replaceRelayPolicy(try Self.managedPolicy(
            relayURLs: Set(ClientRuntimeTestFixture.relayURLs)
        ))

        let profileUpdates = await endpoint.observedRelayProfileUpdates().count
            - initialProfileUpdates
        #expect(profileUpdates == 1)
        #expect(await endpoint.observedCloseCallCount() == 0)
        #expect(await runtime.snapshot().endpointID == fixture.endpointID)
        await runtime.stop()
    }

    @Test
    func hostManagedPolicyRefreshMutatesEndpointExactlyOnce() async throws {
        let fixture = try HostRuntimeFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: TestIrohHostBroker(
                registrationBinding: fixture.binding,
                discovery: fixture.discovery
            ),
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            handleTransport: { session, _ in await session.close() }
        )
        try await runtime.start()
        let initialProfileUpdates = await endpoint.observedRelayProfileUpdates().count

        try await runtime.replaceRelayPolicy(try Self.managedPolicy(
            relayURLs: fixture.managedRelays
        ))

        let profileUpdates = await endpoint.observedRelayProfileUpdates().count
            - initialProfileUpdates
        #expect(profileUpdates == 1)
        #expect(await endpoint.observedCloseCallCount() == 0)
        #expect(await runtime.snapshot().endpointID == fixture.endpointID)
        await runtime.stop()
    }

    @Test
    func clientManagedPolicyFailureLeavesEndpointOpen() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: TestIrohClientBroker(
                binding: fixture.binding,
                discovery: fixture.discovery
            ),
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { fixture.now }
        )
        try await runtime.start()
        await endpoint.setRelayUpdateShouldFail(true)

        await #expect(throws: TestIrohTransportError.relayUpdateFailed) {
            try await runtime.replaceRelayPolicy(try Self.managedPolicy(
                relayURLs: Set(ClientRuntimeTestFixture.relayURLs)
            ))
        }

        #expect(await endpoint.observedCloseCallCount() == 0)
        await runtime.stop()
    }

    @Test
    func hostManagedPolicyFailureLeavesEndpointOpen() async throws {
        let fixture = try HostRuntimeFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: TestIrohHostBroker(
                registrationBinding: fixture.binding,
                discovery: fixture.discovery
            ),
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            handleTransport: { session, _ in await session.close() }
        )
        try await runtime.start()
        await endpoint.setRelayUpdateShouldFail(true)

        await #expect(throws: TestIrohTransportError.relayUpdateFailed) {
            try await runtime.replaceRelayPolicy(try Self.managedPolicy(
                relayURLs: fixture.managedRelays
            ))
        }

        #expect(await endpoint.observedCloseCallCount() == 0)
        await runtime.stop()
    }

    @Test
    func clientOverrideInstallsCustomProfileAtBind() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let custom = try CmxIrohCustomRelayProfile(
            relays: [CmxIrohCustomRelay(url: "https://private.example.net:8443/")]
        )
        let profile = CmxIrohEndpointRelayProfile(customProfile: custom)
        let configuration = CmxIrohClientRuntimeConfiguration(
            accountID: fixture.configuration.accountID,
            deviceID: fixture.configuration.deviceID,
            appInstanceID: fixture.configuration.appInstanceID,
            clientNamespace: fixture.configuration.clientNamespace,
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
            discovery: fixture.discovery
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
        #expect(await endpoint.observedRelayProfileUpdates().isEmpty)
        #expect(await factory.observedConfigurations().first?.relayProfile == profile)
        await runtime.stop()
    }

    @Test
    func hostOverrideInstallsCustomProfileAtBind() async throws {
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
        #expect(await factory.observedConfigurations().first?.relayProfile == profile)
        await runtime.stop()
    }

    @Test
    func clientReplacesCustomProfileWithoutClosingEndpoint() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let initial = CmxIrohEndpointRelayProfile(
            customProfile: try CmxIrohCustomRelayProfile(
                relays: [CmxIrohCustomRelay(url: "https://first.example.net/")]
            )
        )
        let replacement = CmxIrohEndpointRelayProfile(
            customProfile: try CmxIrohCustomRelayProfile(
                relays: [CmxIrohCustomRelay(url: "https://second.example.net:8443/")]
            )
        )
        let configuration = CmxIrohClientRuntimeConfiguration(
            accountID: fixture.configuration.accountID,
            deviceID: fixture.configuration.deviceID,
            appInstanceID: fixture.configuration.appInstanceID,
            clientNamespace: fixture.configuration.clientNamespace,
            tag: fixture.configuration.tag,
            displayName: fixture.configuration.displayName,
            identity: fixture.identity,
            capabilities: fixture.configuration.capabilities,
            managedRelayURLs: fixture.configuration.managedRelayURLs,
            endpointRelayProfile: initial
        )
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: TestIrohClientBroker(
                binding: fixture.binding,
                discovery: fixture.discovery
            ),
            configuration: configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { fixture.now }
        )
        try await runtime.start()

        try await runtime.replaceRelayProfile(replacement)

        #expect(await endpoint.observedRelayProfileUpdates().last == replacement)
        #expect(await endpoint.observedCloseCallCount() == 0)
        #expect(await runtime.snapshot().endpointID == fixture.endpointID)
        await runtime.stop()
    }

    @Test
    func hostReplacesCustomProfileWithoutClosingEndpoint() async throws {
        let fixture = try HostRuntimeFixture()
        let initial = CmxIrohEndpointRelayProfile(
            customProfile: try CmxIrohCustomRelayProfile(
                relays: [CmxIrohCustomRelay(url: "https://first.example.net/")]
            )
        )
        let replacement = CmxIrohEndpointRelayProfile(
            customProfile: try CmxIrohCustomRelayProfile(
                relays: [CmxIrohCustomRelay(url: "https://second.example.net:8443/")]
            )
        )
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: TestIrohHostBroker(
                registrationBinding: fixture.binding,
                discovery: fixture.discovery
            ),
            configuration: fixture.configuration(endpointRelayProfile: initial),
            pendingRevocations: fixture.pendingRevocations(),
            handleTransport: { session, _ in await session.close() }
        )
        try await runtime.start()

        try await runtime.replaceRelayProfile(replacement)

        #expect(await endpoint.observedRelayProfileUpdates().last == replacement)
        #expect(await endpoint.observedCloseCallCount() == 0)
        #expect(await runtime.snapshot().endpointID == fixture.endpointID)
        await runtime.stop()
    }

    private static func managedPolicy(
        relayURLs: Set<String>
    ) throws -> CmxIrohEffectiveRelayPolicy {
        let profile = try CmxIrohEndpointRelayProfile(managedRelayURLs: relayURLs)
        return CmxIrohEffectiveRelayPolicy(
            endpointRelayProfile: profile,
            managedSnapshot: nil,
            managedPolicy: nil,
            requestedConfiguration: nil,
            effectivePreference: .automatic,
            source: .managed,
            usedCachedPolicy: false,
            preferenceRevision: nil
        )
    }
}
