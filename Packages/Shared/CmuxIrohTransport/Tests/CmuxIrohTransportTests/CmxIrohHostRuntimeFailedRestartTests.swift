import CMUXMobileCore
import Foundation
import Testing

@testable import CmuxIrohTransport

extension CmxIrohHostRuntimeTests {
    /// Pins the contract the macOS failure-recovery reconcile depends on:
    /// a non-transient broker rejection during a registration refresh fails
    /// closed (endpoint torn down, deactivation notified, terminal `.failed`
    /// phase), and a later `start()` on the same runtime succeeds once the
    /// broker accepts registration again. If `.failed` ever stops allowing
    /// `start()`, the app-layer recovery silently degrades back to the
    /// restart-only wedge.
    @Test("non-transient refresh rejection fails closed, then start() recovers")
    func nonTransientRefreshRejectionFailsClosedThenRestarts() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try HostRuntimeFixture(now: now, publicHintLifetime: 60 * 60)
        let firstEndpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let restartEndpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            subsequentRegistrationErrors: [
                .rejected(
                    statusCode: 409,
                    code: "binding_replacement_requires_revocation"
                ),
            ]
        )
        let clock = HostRegistrationRenewalClock(now: now)
        let deactivations = CmxIrohTestCounter()
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(
                endpoints: [firstEndpoint, restartEndpoint]
            ),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { clock.now() },
            registrationClock: clock,
            handleTransport: { session, _ in await session.close() },
            handleDeactivation: { _ in
                await deactivations.increment()
            }
        )

        try await runtime.start()
        #expect(await runtime.snapshot().state == .active)

        await clock.waitUntilSleeping()
        let renewalDeadline = try #require(clock.observedSleepDeadlines().first)
        clock.advance(to: renewalDeadline)
        await broker.waitForRegistrationCount(2)
        try await waitForLifecyclePhase(.failed, runtime: runtime)

        #expect(await runtime.snapshot().state == .failed)
        #expect(await deactivations.value() == 1)
        #expect(await firstEndpoint.observedCloseCallCount() == 1)

        try await runtime.start()

        #expect(await broker.observedRegistrationCount() == 3)
        #expect(await runtime.snapshot().state == .active)
        await runtime.stop()
    }

    private func waitForLifecyclePhase(
        _ phase: CmxIrohHostRuntime.LifecyclePhase,
        runtime: CmxIrohHostRuntime
    ) async throws {
        for _ in 0 ..< 20_000 {
            if await runtime.lifecyclePhase == phase { return }
            await Task.yield()
        }
        Issue.record("runtime never reached \(String(describing: phase))")
    }
}

private actor CmxIrohTestCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}
