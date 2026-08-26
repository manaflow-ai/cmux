import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite struct CmxIrohDebugRelayOverrideTests {
    @Test func parsesCanonicalHTTPSOriginAndAddsTrailingSlash() throws {
        let profile = try #require(
            CmxIrohDebugRelayOverride.profile(rawValue: " https://relay-test.example.com ")
        )
        #expect(profile.allowedRelayURLs == ["https://relay-test.example.com/"])
        #expect(profile.source == .custom)
        #expect(profile.activeRelays.map(\.url) == ["https://relay-test.example.com/"])
    }

    @Test func keepsExplicitPort() throws {
        let profile = try #require(
            CmxIrohDebugRelayOverride.profile(rawValue: "https://relay-test.example.com:8443/")
        )
        #expect(profile.allowedRelayURLs == ["https://relay-test.example.com:8443/"])
    }

    @Test(arguments: [
        nil,
        "",
        "   ",
        "http://insecure.example.com/",
        "https://relay.example.com/path",
        "https://relay.example.com/?q=1",
        "https://user:pw@relay.example.com/",
        "not a url",
    ] as [String?])
    func rejectsUnusableValues(_ raw: String?) {
        #expect(CmxIrohDebugRelayOverride.profile(rawValue: raw) == nil)
    }

    @Test func environmentWinsOverDefaults() throws {
        let suiteName = "cmux-debug-relay-override-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            "https://from-defaults.example.com/",
            forKey: CmxIrohDebugRelayOverride.key
        )
        #expect(
            CmxIrohDebugRelayOverride.rawValue(
                environment: [CmxIrohDebugRelayOverride.key: "https://from-env.example.com/"],
                defaults: defaults
            ) == "https://from-env.example.com/"
        )
        #expect(
            CmxIrohDebugRelayOverride.rawValue(
                environment: [:],
                defaults: defaults
            ) == "https://from-defaults.example.com/"
        )
    }

    @Test func hostResolutionPrefersOverride() throws {
        let fixture = try HostRuntimeFixture()
        let override = try #require(
            CmxIrohDebugRelayOverride.profile(rawValue: "https://relay-test.example.com/")
        )
        let resolved = try fixture.configuration.resolvedEndpointRelayProfile(debugOverride: override)
        #expect(resolved == override)

        let managed = try fixture.configuration.resolvedEndpointRelayProfile(debugOverride: nil)
        #expect(managed.source == .managed)
        #expect(managed.allowedRelayURLs == fixture.managedRelays)
    }

    /// A host without a verifiable cached policy is configured with the
    /// relay-less `.unavailableManagedSelection` placeholder. The debug
    /// override must still win at bind time, or the endpoint binds with zero
    /// relays and can never dial the forced test relay. The override is a
    /// custom profile and custom relays are exempt from the
    /// withhold-until-registered ordering, so it stays installed at bind.
    @Test func overrideWinsOverUnavailableManagedSelectionAtBind() async throws {
        let fixture = try HostRuntimeFixture()
        let override = try #require(
            CmxIrohDebugRelayOverride.profile(rawValue: "https://relay-test.example.com/")
        )
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let factory = TestIrohEndpointFactory(endpoints: [endpoint])
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery
        )
        let runtime = CmxIrohHostRuntime(
            factory: factory,
            broker: broker,
            configuration: fixture.configuration(
                endpointRelayProfile: .unavailableManagedSelection
            ),
            pendingRevocations: fixture.pendingRevocations(),
            handleTransport: { session, _ in await session.close() }
        )

        try await runtime.start(debugRelayOverride: override)

        let boundConfigurations = await factory.observedConfigurations()
        #expect(boundConfigurations.count == 1)
        #expect(boundConfigurations.first?.relayProfile == override)
        // Installed at bind: no post-registration relay swap replaces it.
        #expect(await endpoint.observedRelayProfileUpdates().isEmpty)
        #expect(await runtime.snapshot().state == .active)
        await runtime.stop()
    }

    /// Without the override, a host configured with
    /// `.unavailableManagedSelection` still binds with zero relays,
    /// preserving the withhold-managed-relays-until-registered ordering
    /// (manaflow-ai/cmux#10867): no managed relay may be dialable before
    /// broker admission.
    @Test func withoutOverrideUnavailableManagedSelectionBindsEmpty() async throws {
        let fixture = try HostRuntimeFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let factory = TestIrohEndpointFactory(endpoints: [endpoint])
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery
        )
        let runtime = CmxIrohHostRuntime(
            factory: factory,
            broker: broker,
            configuration: fixture.configuration(
                endpointRelayProfile: .unavailableManagedSelection
            ),
            pendingRevocations: fixture.pendingRevocations(),
            handleTransport: { session, _ in await session.close() }
        )

        try await runtime.start(debugRelayOverride: nil)

        let boundConfigurations = await factory.observedConfigurations()
        #expect(boundConfigurations.count == 1)
        #expect(boundConfigurations.first?.relayProfile.activeRelays.isEmpty == true)
        #expect(boundConfigurations.first?.relayProfile.allowedRelayURLs.isEmpty == true)
        #expect(await endpoint.observedRelayProfileUpdates().isEmpty)
        #expect(await runtime.snapshot().state == .active)
        await runtime.stop()
    }

    @Test func clientResolutionPrefersOverride() throws {
        let fixture = try ClientRuntimeTestFixture()
        let override = try #require(
            CmxIrohDebugRelayOverride.profile(rawValue: "https://relay-test.example.com/")
        )
        let resolved = try fixture.configuration.resolvedEndpointRelayProfile(debugOverride: override)
        #expect(resolved == override)

        let managed = try fixture.configuration.resolvedEndpointRelayProfile(debugOverride: nil)
        #expect(managed.source == .managed)
        #expect(managed.allowedRelayURLs == Set(ClientRuntimeTestFixture.relayURLs))
    }
}
