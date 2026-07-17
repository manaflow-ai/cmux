import Testing
@testable import CmuxIrohTransport

extension CmxIrohHostRuntimeTests {
    @Test
    func validatedBindingPublishesBeforeRelayCredentialInstallationCompletes() async throws {
        let fixture = try HostRuntimeFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let gate = HostRuntimeSuspensionGate()
        let bindings = HostRuntimeBindingRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: TestIrohHostBroker(
                registrationBinding: fixture.binding,
                discovery: fixture.discovery,
                relayIssueHook: { await gate.suspend() }
            ),
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            handleTransport: { session, _ in await session.close() },
            handleBinding: { _, _, _ in await bindings.record() }
        )
        let start = Task { try await runtime.start() }
        await gate.waitUntilSuspended()

        #expect(await bindings.count() == 1)

        await gate.resume()
        try await start.value
        await runtime.stop()
    }

    @Test
    func validatedBindingPublishesBeforeLANAdvertisementCompletes() async throws {
        let fixture = try HostRuntimeFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let gate = HostRuntimeSuspensionGate()
        let bindings = HostRuntimeBindingRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: TestIrohHostBroker(
                registrationBinding: fixture.binding,
                discovery: fixture.discovery
            ),
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            handleTransport: { session, _ in await session.close() },
            handleBinding: { _, _, _ in await bindings.record() },
            handleLANPolicy: { _, _ in await gate.suspend() }
        )
        let start = Task { try await runtime.start() }
        await gate.waitUntilSuspended()

        #expect(await bindings.count() == 1)

        await gate.resume()
        try await start.value
        await runtime.stop()
    }

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

private actor HostRuntimeSuspensionGate {
    private var suspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        suspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { resumeWaiter = $0 }
    }

    func waitUntilSuspended() async {
        if suspended { return }
        await withCheckedContinuation { suspensionWaiters.append($0) }
    }

    func resume() {
        resumeWaiter?.resume()
        resumeWaiter = nil
    }
}
