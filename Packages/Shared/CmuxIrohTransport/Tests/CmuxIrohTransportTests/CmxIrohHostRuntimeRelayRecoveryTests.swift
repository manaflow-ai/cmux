import CMUXMobileCore
import Foundation
import Testing

@testable import CmuxIrohTransport

/// Regression coverage for cmux#10873: a Mac that activated during a relay
/// policy outage (expired policy cache, persistently failing refresh) runs
/// with zero managed relays and publishes a direct-only registration. When a
/// later policy refresh finally succeeds, installing the recovered policy
/// must both attach the managed relay on the live endpoint AND republish the
/// registration, without an app restart, so remote clients can reach the
/// host again.
struct CmxIrohHostRuntimeRelayRecoveryTests {
    @Test("relay policy recovery after outage attaches and republishes")
    func recoveryAfterOutageAttachesAndRepublishes() async throws {
        let fixture = try HostRuntimeFixture()
        let recoveredRelayURL = HostRuntimeFixture.relayURLs[2]
        // The endpoint has no relay hints: exactly the outage shape, where the
        // host bound with `.unavailableManagedSelection` (zero relays).
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery
        )
        let bindings = HostRuntimeBindingRecorder()
        let routes = HostRuntimeRouteRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration(
                endpointRelayProfile: .unavailableManagedSelection,
                managedRelayURLs: []
            ),
            pendingRevocations: fixture.pendingRevocations(),
            handleTransport: { session, _ in await session.close() },
            handleBinding: { _, _, _ in await bindings.record() },
            handleRoute: { binding, pathHints in
                await routes.record(binding: binding, pathHints: pathHints)
            }
        )

        try await runtime.start()

        // Outage steady state: active, published direct-only, no relays.
        #expect(await runtime.snapshot().state == .active)
        #expect(await bindings.count() == 1)
        #expect(await endpoint.observedRelayProfileUpdates().isEmpty)

        // A later policy refresh succeeds and the recovered policy is
        // installed on the running host.
        try await runtime.replaceRelayPolicy(
            Self.recoveredPolicy(selectedRelayURL: recoveredRelayURL)
        )

        // Attach: the live endpoint received the recovered relay profile.
        #expect(
            await endpoint.observedRelayProfileUpdates().last?.allowedRelayURLs
                == [recoveredRelayURL]
        )
        // Publish: the host re-registers and republishes without a restart,
        // so the broker can serve the recovered relay route to clients.
        #expect(await bindings.waitForCount(2, timeout: .seconds(5)))
        await runtime.waitForRegistrationRefreshRoundsForTesting()
        #expect(await routes.values().count >= 2)

        await runtime.stop()
    }

    /// A repeated install of an unchanged relay profile (every periodic
    /// policy refresh success re-applies the effective policy) must NOT force
    /// a broker registration round each time.
    @Test("unchanged relay profile reinstall does not republish")
    func unchangedProfileReinstallDoesNotRepublish() async throws {
        let fixture = try HostRuntimeFixture()
        let recoveredRelayURL = HostRuntimeFixture.relayURLs[2]
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery
        )
        let bindings = HostRuntimeBindingRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration(
                endpointRelayProfile: .unavailableManagedSelection,
                managedRelayURLs: []
            ),
            pendingRevocations: fixture.pendingRevocations(),
            handleTransport: { session, _ in await session.close() },
            handleBinding: { _, _, _ in await bindings.record() }
        )
        try await runtime.start()
        #expect(await bindings.count() == 1)

        let recovered = Self.recoveredPolicy(selectedRelayURL: recoveredRelayURL)
        try await runtime.replaceRelayPolicy(recovered)
        #expect(await bindings.waitForCount(2, timeout: .seconds(5)))
        await runtime.waitForRegistrationRefreshRoundsForTesting()
        let publishedAfterRecovery = await bindings.count()

        // Same policy again: no relay change, no forced round.
        try await runtime.replaceRelayPolicy(recovered)
        await runtime.waitForRegistrationRefreshRoundsForTesting()
        #expect(await bindings.count() == publishedAfterRecovery)

        await runtime.stop()
    }

    /// An effective policy whose managed catalog carries the fixture fleet
    /// and whose endpoint profile selects `selectedRelayURL`.
    private static func recoveredPolicy(
        selectedRelayURL: String
    ) -> CmxIrohEffectiveRelayPolicy {
        let descriptors = HostRuntimeFixture.relayURLs.enumerated().map {
            index, url in
            CmxIrohManagedRelayDescriptor(
                id: "cmux-relay-\(index)",
                provider: "cmux",
                region: "region-\(index)",
                url: url
            )
        }
        let policy = CmxIrohManagedRelayPolicy(
            version: 1,
            policyID: "123e4567-e89b-42d3-a456-426614174777",
            sequence: 9,
            issuedAt: 1_800_000_000,
            notBefore: 1_800_000_000,
            expiresAt: 1_800_003_600,
            audience: "cmux-iroh-relay-policy",
            relayProtocol: "iroh-relay-v1",
            relays: descriptors
        )
        let profile = try! CmxIrohEndpointRelayProfile(
            managedRelayURLs: [selectedRelayURL]
        )
        return CmxIrohEffectiveRelayPolicy(
            endpointRelayProfile: profile,
            managedSnapshot: nil,
            managedPolicy: policy,
            requestedConfiguration: .automatic,
            effectivePreference: .automatic,
            source: .managed,
            usedCachedPolicy: false,
            preferenceRevision: 3
        )
    }
}
