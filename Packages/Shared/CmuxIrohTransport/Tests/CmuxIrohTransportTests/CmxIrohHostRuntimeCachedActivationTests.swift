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

    @Test
    func cachedActivationRetryOwnsNetworkChangeAcrossSuspendedLANRefresh() async throws {
        let fixture = try HostRuntimeFixture()
        let cachedFixture = try fixture.cachedPolicyFixture()
        let now = cachedFixture.now
        let retryDeadline = now.addingTimeInterval(600)
        let endpoint = TestIrohEndpoint(
            identity: fixture.endpointID,
            directAddresses: ["0.0.0.0:55123"]
        )
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            preflightErrors: [
                CmxIrohBrokerCooldownError(retryAfterSeconds: 600),
            ]
        )
        let clock = HostRegistrationRenewalClock(now: now)
        let lanGate = CachedActivationLANRefreshGate()
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
            handleLANRefresh: { await lanGate.suspend() }
        )

        try await runtime.start()
        await clock.waitUntilSleepCount(1)
        await endpoint.emit(.networkChanged)
        await lanGate.waitUntilSuspended()

        clock.advance(to: retryDeadline)
        #expect(await broker.waitForRegistrationCount(1, timeout: .seconds(1)))
        await clock.waitUntilSleepCount(2)
        await endpoint.setDirectAddresses(["0.0.0.0:55124"])

        await lanGate.resume()
        await lanGate.waitUntilFinished()
        #expect(await runtime.localDirectAddresses() == ["0.0.0.0:55124"])
        #expect(
            !(await broker.waitForRegistrationCount(2, timeout: .milliseconds(200))),
            "A network event held in LAN refresh must not start a second registration"
        )
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

private actor CachedActivationLANRefreshGate {
    private var suspended = false
    private var finished = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishedWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        suspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { resumeWaiter = $0 }
        finished = true
        let completions = finishedWaiters
        finishedWaiters.removeAll(keepingCapacity: false)
        for waiter in completions { waiter.resume() }
    }

    func waitUntilSuspended() async {
        if suspended { return }
        await withCheckedContinuation { suspensionWaiters.append($0) }
    }

    func resume() {
        resumeWaiter?.resume()
        resumeWaiter = nil
    }

    func waitUntilFinished() async {
        if finished { return }
        await withCheckedContinuation { finishedWaiters.append($0) }
    }
}
