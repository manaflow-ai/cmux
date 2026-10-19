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
                discovery: fixture.discovery,
                relay: fixture.relayResponse()
            ),
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { fixture.now }
        )
        try await runtime.start()
        try await Self.waitForRelayMutation(endpoint)
        let initialCredentialUpdates = await endpoint.observedRelayUpdates().count
        let initialProfileUpdates = await endpoint.observedRelayProfileUpdates().count

        try await runtime.replaceRelayPolicy(try Self.managedPolicy(
            response: fixture.relayResponse(),
            relayURLs: Set(ClientRuntimeTestFixture.relayURLs),
            now: fixture.now
        ))

        let credentialUpdates = await endpoint.observedRelayUpdates().count
            - initialCredentialUpdates
        let profileUpdates = await endpoint.observedRelayProfileUpdates().count
            - initialProfileUpdates
        #expect(credentialUpdates + profileUpdates == 1)
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
        try await Self.waitForRelayMutation(endpoint)
        let initialCredentialUpdates = await endpoint.observedRelayUpdates().count
        let initialProfileUpdates = await endpoint.observedRelayProfileUpdates().count
        let response = try ClientRuntimeTestFixture().relayResponse()

        try await runtime.replaceRelayPolicy(try Self.managedPolicy(
            response: response,
            relayURLs: fixture.managedRelays,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        ))

        let credentialUpdates = await endpoint.observedRelayUpdates().count
            - initialCredentialUpdates
        let profileUpdates = await endpoint.observedRelayProfileUpdates().count
            - initialProfileUpdates
        #expect(credentialUpdates + profileUpdates == 1)
        #expect(await endpoint.observedCloseCallCount() == 0)
        #expect(await runtime.snapshot().endpointID == fixture.endpointID)
        await runtime.stop()
    }

    @Test
    func clientManagedPolicyFailureDeactivatesUncommittedCoordinator() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: TestIrohClientBroker(
                binding: fixture.binding,
                discovery: fixture.discovery,
                relay: fixture.relayResponse()
            ),
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { fixture.now }
        )
        try await runtime.start()
        try await Self.waitForRelayMutation(endpoint)
        await endpoint.setRelayUpdateShouldFail(true)

        await #expect(throws: TestIrohTransportError.relayUpdateFailed) {
            try await runtime.replaceRelayPolicy(try Self.managedPolicy(
                response: fixture.relayResponse(),
                relayURLs: Set(ClientRuntimeTestFixture.relayURLs),
                now: fixture.now
            ))
        }

        #expect(await runtime.relayCoordinator == nil)
        #expect(await endpoint.observedCloseCallCount() == 0)
        await runtime.stop()
    }

    @Test
    func hostManagedPolicyFailureDeactivatesUncommittedCoordinator() async throws {
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
        try await Self.waitForRelayMutation(endpoint)
        await endpoint.setRelayUpdateShouldFail(true)
        let response = try ClientRuntimeTestFixture().relayResponse()

        await #expect(throws: TestIrohTransportError.relayUpdateFailed) {
            try await runtime.replaceRelayPolicy(try Self.managedPolicy(
                response: response,
                relayURLs: fixture.managedRelays,
                now: Date(timeIntervalSince1970: 1_800_000_000)
            ))
        }

        #expect(await runtime.relayCoordinator == nil)
        #expect(await endpoint.observedCloseCallCount() == 0)
        await runtime.stop()
    }

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
                discovery: fixture.discovery,
                relay: fixture.relayResponse()
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
        response: CmxIrohRelayTokenResponse,
        relayURLs: Set<String>,
        now: Date
    ) throws -> CmxIrohEffectiveRelayPolicy {
        let profile = try CmxIrohEndpointRelayProfile(
            managedRelayURLs: relayURLs,
            relays: response.relayConfigurations(now: now)
        )
        return CmxIrohEffectiveRelayPolicy(
            endpointRelayProfile: profile,
            managedSnapshot: nil,
            managedPolicy: nil,
            requestedConfiguration: nil,
            effectivePreference: .automatic,
            source: .managed,
            usedCachedPolicy: false,
            preferenceRevision: nil,
            relayBootstrap: response
        )
    }

    private static func waitForRelayMutation(_ endpoint: TestIrohEndpoint) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            let credentialUpdates = await endpoint.observedRelayUpdates().count
            let profileUpdates = await endpoint.observedRelayProfileUpdates().count
            if credentialUpdates + profileUpdates > 0 { return }
            await Task.yield()
        }
        let credentialUpdates = await endpoint.observedRelayUpdates().count
        let profileUpdates = await endpoint.observedRelayProfileUpdates().count
        let counts = "credential updates: \(credentialUpdates), "
            + "profile updates: \(profileUpdates)"
        Issue.record("Timed out waiting for relay mutation (\(counts))")
        throw RelayMutationTimeout()
    }
}

private struct RelayMutationTimeout: Error {}
