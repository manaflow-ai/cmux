import CMUXMobileCore
import Foundation
import Testing

@testable import CmuxIrohTransport

extension CmxIrohHostRuntimeTests {
    /// Regression for the advertise-before-ready warm-up race
    /// (https://github.com/manaflow-ai/cmux/issues/9724): a Mac must not
    /// publish its binding or route hints while its home relay is still
    /// warming up, because clients immediately burn doomed dials against an
    /// endpoint that cannot yet accept them. The binding and route may only
    /// be published once the relay is usable, with the post-relay hints, and
    /// exactly once.
    @Test("binding publication waits for a usable home relay")
    func bindingPublicationWaitsForUsableHomeRelay() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try HostRuntimeFixture(now: now)
        let readyBinding = try HostRuntimeFixture.binding(
            endpointID: fixture.endpointID.endpointID,
            bindingID: fixture.binding.bindingID,
            publicHintObservedAt: now,
            publicHintExpiresAt: now.addingTimeInterval(60 * 60)
        )
        let relayHint = try #require(readyBinding.pathHints.first)
        let readyDiscovery = try HostRuntimeFixture.discovery(
            binding: readyBinding,
            relays: HostRuntimeFixture.relayURLs
        )
        // The endpoint gains its usable relay hint only after the relay
        // credential coordinator installs the first credential, exactly like
        // a cold production launch.
        let endpoint = TestIrohEndpoint(
            identity: fixture.endpointID,
            pathHintsAfterRelayReplacement: [relayHint]
        )
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            subsequentRegistrationBindings: [readyBinding],
            subsequentDiscoveries: [readyDiscovery]
        )
        let bindings = HostRuntimeBindingRecorder()
        let routes = HostRuntimeRouteRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { now },
            handleTransport: { session, _ in await session.close() },
            handleBinding: { _, _, _ in await bindings.record() },
            handleRoute: { binding, pathHints in
                await routes.record(binding: binding, pathHints: pathHints)
            }
        )

        try await runtime.start()

        // No usable home relay exists yet: the Mac must not be
        // discoverable-but-undialable.
        #expect(await bindings.count() == 0)
        #expect(await routes.values().isEmpty)
        #expect(await runtime.snapshot().state == .active)

        // The relay comes up through the normal credential installation path.
        // Publication must follow, exactly once, with the post-relay hints.
        #expect(await bindings.waitForCount(1, timeout: .seconds(5)))
        let republished = await routes.values()
        #expect(republished.map(\.binding.bindingID) == [fixture.binding.bindingID])
        #expect(republished.map(\.pathHints) == [[relayHint]])
        #expect(!(await bindings.waitForCount(2, timeout: .milliseconds(300))))

        await runtime.stop()
    }
}
