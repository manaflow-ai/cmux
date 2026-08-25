import CMUXMobileCore
import Foundation
import Testing

@testable import CmuxIrohTransport

extension CmxIrohHostRuntimeTests {
    @Test
    func cachedActivationCoalescesNetworkRefreshWithRegistrationRetry() async throws {
        let fixture = try HostRuntimeFixture()
        let cachedFixture = try fixture.cachedPolicyFixture()
        let now = cachedFixture.now
        let retryDeadline = now.addingTimeInterval(600)
        let endpoint = TestIrohEndpoint(
            identity: fixture.endpointID,
            directAddresses: ["0.0.0.0:55_123"]
        )
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            preflightErrors: [
                CmxIrohBrokerCooldownError(retryAfterSeconds: 600),
            ]
        )
        let clock = HostRegistrationRenewalClock(now: now)
        let lanRefreshes = HostRuntimeLANRefreshRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration(
                cachedHostPolicy: try cachedFixture.policy()
            ),
            pendingRevocations: fixture.pendingRevocations(),
            now: { clock.now() },
            registrationClock: clock,
            registrationRetryJitter: { 0 },
            handleTransport: { session, _ in await session.close() },
            handleLANRefresh: { await lanRefreshes.record() }
        )

        try await runtime.start()
        await clock.waitUntilSleepCount(1)
        #expect(clock.observedSleepDeadlines() == [retryDeadline])

        await endpoint.emit(.networkChanged)
        #expect(await lanRefreshes.waitForRefresh(timeout: .seconds(1)))
        #expect(
            !(await broker.waitForRegistrationCount(1, timeout: .milliseconds(200))),
            "A cached activation must keep network refreshes behind its retry deadline"
        )
        #expect(clock.observedSleepDeadlines() == [retryDeadline])

        clock.advance(to: retryDeadline)
        #expect(await broker.waitForRegistrationCount(1, timeout: .seconds(1)))
        await clock.waitUntilSleepCount(2)
        let renewalDeadline = try #require(
            CmxIrohHostRuntime.registrationRenewalDeadline(
                binding: fixture.binding,
                now: retryDeadline
            )
        )
        #expect(clock.observedSleepDeadlines() == [retryDeadline, renewalDeadline])

        await runtime.stop()
    }
}
