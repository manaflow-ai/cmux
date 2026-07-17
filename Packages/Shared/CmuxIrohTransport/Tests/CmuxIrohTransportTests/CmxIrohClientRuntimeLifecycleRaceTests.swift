import CMUXMobileCore
import Testing
@testable import CmuxIrohTransport

extension CmxIrohClientRuntimeTests {
    @Test
    func stoppedStartupCannotPublishDiscoveryGenerationAfterBindingHandlerResumes() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let gate = ClientRuntimeBindingHandlerGate(blockedCalls: [1])
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: TestIrohClientBroker(
                binding: fixture.binding,
                discovery: fixture.discovery,
                relay: fixture.relayResponse()
            ),
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { fixture.now },
            handleBinding: { _, _ in
                await gate.handleBinding()
                return true
            }
        )
        let start = Task { try await runtime.start() }
        await gate.waitForCall(1)

        await runtime.stop()
        await gate.release(call: 1)

        switch await start.result {
        case .success:
            Issue.record("superseded startup unexpectedly succeeded")
        case .failure(let error):
            #expect(error as? CmxIrohClientRuntimeError == .superseded)
        }
        #expect(await runtime.liveDiscoverySnapshotGeneration() == 0)
        #expect(await runtime.snapshot().state == .inactive)
    }

    @Test
    func stoppedRefreshCannotPublishDiscoveryGenerationAfterBindingHandlerResumes() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let gate = ClientRuntimeBindingHandlerGate(blockedCalls: [2])
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: TestIrohClientBroker(
                binding: fixture.binding,
                discovery: fixture.discovery,
                relay: fixture.relayResponse()
            ),
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { fixture.now },
            handleBinding: { _, _ in
                await gate.handleBinding()
                return true
            }
        )
        try await runtime.start()
        #expect(await runtime.liveDiscoverySnapshotGeneration() == 1)
        let refresh = Task { await runtime.refreshLiveDiscovery() }
        await gate.waitForCall(2)

        await runtime.stop()
        await gate.release(call: 2)

        #expect(!(await refresh.value))
        #expect(await runtime.liveDiscoverySnapshotGeneration() == 1)
        #expect(await runtime.snapshot().state == .inactive)
    }

    @Test
    func refreshAwaitsAlreadyScheduledSuccessorWithoutRequestingThirdRefresh() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let secondRegistration = HostRuntimeRegistrationGate()
        let thirdRegistration = HostRuntimeRegistrationGate()
        let broker = TestIrohClientBroker(
            binding: fixture.binding,
            discovery: fixture.discovery,
            relay: fixture.relayResponse(),
            registrationHook: { count in
                if count == 2 { await secondRegistration.waitOnce() }
                if count == 3 { await thirdRegistration.waitOnce() }
            }
        )
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { fixture.now }
        )
        try await runtime.start()
        await broker.setRegistrationError(
            CmxIrohTrustBrokerClientError.connectivity,
            forRegistrationCount: 2
        )
        let refresh = Task { await runtime.refreshLiveDiscovery() }
        await broker.waitForRegistrationCount(2)
        await endpoint.emit(.networkChanged)
        for _ in 0..<1_000 where !(await runtime.registrationRefreshPending) {
            await Task.yield()
        }
        #expect(await runtime.registrationRefreshPending)

        await secondRegistration.open()
        await broker.waitForRegistrationCount(3)
        await thirdRegistration.open()

        #expect(await refresh.value)
        #expect(!(await broker.waitForRegistrationCount(4, timeout: .milliseconds(100))))
        await runtime.stop()
    }

    @Test
    func networkChangeDuringRegistrationRequestsRefreshAfterStartup() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let broker = TestIrohClientBroker(
            binding: fixture.binding,
            discovery: fixture.discovery,
            relay: fixture.relayResponse(),
            registrationHook: { count in
                if count == 1 { await endpoint.emit(.networkChanged) }
            }
        )
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { fixture.now }
        )

        try await runtime.start()

        #expect(
            await broker.waitForRegistrationCount(2, timeout: .seconds(1))
        )
        await runtime.stop()
    }

    @Test
    func networkChangeDuringActiveRefreshRequestsAnotherRegistration() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let gate = HostRuntimeRegistrationGate()
        let broker = TestIrohClientBroker(
            binding: fixture.binding,
            discovery: fixture.discovery,
            relay: fixture.relayResponse(),
            registrationHook: { count in
                if count == 2 { await gate.waitOnce() }
            }
        )
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { fixture.now }
        )
        try await runtime.start()

        await endpoint.emit(.networkChanged)
        await broker.waitForRegistrationCount(2)
        await endpoint.emit(.networkChanged)
        await gate.open()

        #expect(
            await broker.waitForRegistrationCount(3, timeout: .seconds(1))
        )
        await runtime.stop()
    }

    @Test
    func stoppedRuntimeIgnoresSupersededRefreshFailure() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let gate = HostRuntimeRegistrationGate()
        let broker = TestIrohClientBroker(
            binding: fixture.binding,
            discovery: fixture.discovery,
            relay: fixture.relayResponse(),
            registrationHook: { count in
                if count == 2 { await gate.waitOnce() }
            }
        )
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { fixture.now }
        )
        try await runtime.start()
        await endpoint.emit(.networkChanged)
        await broker.waitForRegistrationCount(2)
        let refresh = await runtime.registrationRefreshTask

        await runtime.stop()
        await gate.open()
        try? await refresh?.value

        #expect(await runtime.snapshot().state == .inactive)
        #expect(await endpoint.observedCloseCallCount() == 1)
    }

    @Test
    func signedOutRuntimeIgnoresSupersededRefreshFailure() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let gate = HostRuntimeRegistrationGate()
        let broker = TestIrohClientBroker(
            binding: fixture.binding,
            discovery: fixture.discovery,
            relay: fixture.relayResponse(),
            registrationHook: { count in
                if count == 2 { await gate.waitOnce() }
            }
        )
        let runtime = try CmxIrohClientRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { fixture.now }
        )
        try await runtime.start()
        await endpoint.emit(.networkChanged)
        await broker.waitForRegistrationCount(2)
        let refresh = await runtime.registrationRefreshTask

        let preparation = await runtime.deactivateForSignOut()
        await gate.open()
        try? await refresh?.value

        #expect(preparation.wasPersisted)
        #expect(await runtime.snapshot().state == .inactive)
        #expect(await endpoint.observedCloseCallCount() == 1)
    }
}

private actor ClientRuntimeBindingHandlerGate {
    private let blockedCalls: Set<Int>
    private var callCount = 0
    private var observedCalls: Set<Int> = []
    private var callWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var releaseWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var releasedCalls: Set<Int> = []

    init(blockedCalls: Set<Int>) {
        self.blockedCalls = blockedCalls
    }

    func handleBinding() async {
        callCount += 1
        let call = callCount
        observedCalls.insert(call)
        let waiters = callWaiters.removeValue(forKey: call) ?? []
        for waiter in waiters { waiter.resume() }
        guard blockedCalls.contains(call), !releasedCalls.contains(call) else { return }
        await withCheckedContinuation { releaseWaiters[call] = $0 }
    }

    func waitForCall(_ call: Int) async {
        if observedCalls.contains(call) { return }
        await withCheckedContinuation { callWaiters[call, default: []].append($0) }
    }

    func release(call: Int) {
        releasedCalls.insert(call)
        releaseWaiters.removeValue(forKey: call)?.resume()
    }
}
