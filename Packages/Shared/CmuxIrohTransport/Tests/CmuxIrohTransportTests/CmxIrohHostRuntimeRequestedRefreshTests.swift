import CMUXMobileCore
import Foundation
import Testing

@testable import CmuxIrohTransport

extension CmxIrohHostRuntimeTests {
    /// A server-directed nudge asks the host to re-register now instead of
    /// waiting out the hint-expiry renewal timer. The refresh must run one
    /// extra broker registration round and leave the runtime active.
    @Test("requestRegistrationRefresh runs an immediate broker round")
    func requestRegistrationRefreshRunsImmediateBrokerRound() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try HostRuntimeFixture(now: now, publicHintLifetime: 60 * 60)
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery
        )
        let clock = HostRegistrationRenewalClock(now: now)
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { clock.now() },
            registrationClock: clock,
            handleTransport: { session, _ in await session.close() }
        )

        try await runtime.start()
        #expect(await broker.observedRegistrationCount() == 1)

        await runtime.requestRegistrationRefresh()
        await broker.waitForRegistrationCount(2)

        #expect(await broker.observedRegistrationCount() == 2)
        #expect(await runtime.snapshot().state == .active)
        await runtime.stop()
    }

    /// A nudge-triggered refresh that discovers the binding was REPLACED
    /// server-side (the broker returns a different binding id, the re-key
    /// newest-wins case) must fail closed into `.failed` by the time the
    /// await returns — that settled state is what the macOS composition root
    /// reads to decide it must rebuild the runtime and re-register.
    @Test("requestRegistrationRefresh settles failed when the binding was replaced")
    func requestRegistrationRefreshSettlesFailedOnReplacedBinding() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try HostRuntimeFixture(now: now, publicHintLifetime: 60 * 60)
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let replacedBinding = try HostRuntimeFixture.binding(
            endpointID: fixture.endpointID.endpointID,
            bindingID: "123e4567-e89b-42d3-a456-426614174099",
            publicHintObservedAt: now,
            publicHintExpiresAt: now.addingTimeInterval(60 * 60)
        )
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            subsequentRegistrationBindings: [replacedBinding]
        )
        let clock = HostRegistrationRenewalClock(now: now)
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { clock.now() },
            registrationClock: clock,
            handleTransport: { session, _ in await session.close() }
        )

        try await runtime.start()
        #expect(await runtime.snapshot().state == .active)

        await runtime.requestRegistrationRefresh()

        #expect(await runtime.snapshot().state == .failed)
    }

    /// The nudge path must be a no-op on a stopped runtime: no broker round,
    /// no state change.
    @Test("requestRegistrationRefresh is a no-op when inactive")
    func requestRegistrationRefreshNoOpWhenInactive() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try HostRuntimeFixture(now: now, publicHintLifetime: 60 * 60)
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery
        )
        let clock = HostRegistrationRenewalClock(now: now)
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { clock.now() },
            registrationClock: clock,
            handleTransport: { session, _ in await session.close() }
        )

        try await runtime.start()
        await runtime.stop()
        let countAfterStop = await broker.observedRegistrationCount()

        await runtime.requestRegistrationRefresh()
        await Task.yield()

        #expect(await broker.observedRegistrationCount() == countAfterStop)
        #expect(await runtime.snapshot().state == .inactive)
    }
}
