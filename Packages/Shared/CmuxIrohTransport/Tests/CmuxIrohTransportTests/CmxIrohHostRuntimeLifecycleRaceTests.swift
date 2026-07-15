import Testing
@testable import CmuxIrohTransport

extension CmxIrohHostRuntimeTests {
    @Test
    func stoppedHostIgnoresSupersededRefreshFailure() async throws {
        let fixture = try HostRuntimeFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let gate = HostRuntimeRegistrationGate()
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            subsequentRegistrationHook: { await gate.waitOnce() }
        )
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            handleTransport: { session, _ in await session.close() }
        )
        try await runtime.start()
        await endpoint.emit(.networkChanged)
        await broker.waitForRegistrationCount(2)
        let refresh = await runtime.registrationRefreshTask

        await runtime.stop()
        await gate.open()
        await refresh?.value

        #expect(await runtime.snapshot().state == .inactive)
        #expect(await endpoint.observedCloseCallCount() == 1)
    }

    @Test
    func signedOutHostIgnoresSupersededRefreshFailure() async throws {
        let fixture = try HostRuntimeFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let gate = HostRuntimeRegistrationGate()
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            subsequentRegistrationHook: { await gate.waitOnce() }
        )
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            handleTransport: { session, _ in await session.close() }
        )
        try await runtime.start()
        await endpoint.emit(.networkChanged)
        await broker.waitForRegistrationCount(2)
        let refresh = await runtime.registrationRefreshTask

        let preparation = await runtime.deactivateForSignOut()
        await gate.open()
        await refresh?.value

        #expect(preparation.wasPersisted)
        #expect(await runtime.snapshot().state == .inactive)
        #expect(await endpoint.observedCloseCallCount() == 1)
    }
}
