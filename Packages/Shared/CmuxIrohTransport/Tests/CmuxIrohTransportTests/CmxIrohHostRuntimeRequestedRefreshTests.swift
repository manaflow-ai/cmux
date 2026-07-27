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
