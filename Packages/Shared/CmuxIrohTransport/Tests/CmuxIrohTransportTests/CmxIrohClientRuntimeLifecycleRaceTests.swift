import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

extension CmxIrohClientRuntimeTests {
    @Test("foreground recovery owns the registration lane while the endpoint is unbound")
    func foregroundRecoverySerializesRegistrationAcrossEndpointReplacement() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let staleEndpoint = ClientRuntimeBlockingCloseEndpoint(
            identity: fixture.endpointID
        )
        let replacementEndpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let factory = TestIrohEndpointFactory(
            endpoints: [staleEndpoint, replacementEndpoint]
        )
        let broker = TestIrohClientBroker(
            binding: fixture.binding,
            discovery: fixture.discovery,
            relay: fixture.relayResponse()
        )
        let configuration = CmxIrohClientRuntimeConfiguration(
            accountID: fixture.configuration.accountID,
            deviceID: fixture.configuration.deviceID,
            appInstanceID: fixture.configuration.appInstanceID,
            tag: fixture.configuration.tag,
            displayName: fixture.configuration.displayName,
            identity: fixture.configuration.identity,
            capabilities: fixture.configuration.capabilities,
            managedRelayURLs: fixture.configuration.managedRelayURLs,
            endpointRelayProfile: .unavailableCustomOverride
        )
        let runtime = try CmxIrohClientRuntime(
            factory: factory,
            broker: broker,
            configuration: configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { fixture.now }
        )
        try await runtime.start()
        await staleEndpoint.setHealthy(false)

        let foreground = Task { try await runtime.didBecomeActive() }
        await staleEndpoint.waitForCloseStart()
        await runtime.handleSupervisorNetworkChange(
            revision: await runtime.lifecycleRevision
        )
        if let concurrentRefresh = await runtime.registrationRefreshTask {
            _ = try? await concurrentRefresh.value
        }
        await staleEndpoint.releaseClose()

        switch await foreground.result {
        case .success:
            break
        case .failure(let error):
            Issue.record("foreground recovery was superseded by its own refresh: \(error)")
        }
        #expect(await runtime.snapshot().state == .active)
        #expect(await factory.observedConfigurations().count == 2)
        #expect(await broker.observedRegistrations().count == 2)
        #expect(await staleEndpoint.observedCloseCallCount() == 1)
        await runtime.stop()
        await runtime.supervisor.deactivate()
    }

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
        await runtime.handleSupervisorNetworkChange(
            revision: await runtime.lifecycleRevision
        )
        #expect(await runtime.registrationRefreshPending)

        await secondRegistration.open()
        await broker.waitForRegistrationCount(3)
        #expect(await runtime.registrationRefreshTaskID != nil)
        await thirdRegistration.open()

        #expect(await refresh.value)
        #expect(await runtime.registrationRefreshTaskID == nil)
        #expect(!(await runtime.registrationRefreshPending))
        #expect(await broker.observedRegistrations().count == 3)
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
        _ = try? await refresh?.value

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
        _ = try? await refresh?.value

        #expect(preparation.wasPersisted)
        #expect(await runtime.snapshot().state == .inactive)
        #expect(await endpoint.observedCloseCallCount() == 1)
    }
}

private actor ClientRuntimeBlockingCloseEndpoint: CmxIrohEndpoint {
    private let peerIdentity: CmxIrohPeerIdentity
    private let healthStream: AsyncStream<CmxIrohEndpointHealthEvent>
    private let healthContinuation: AsyncStream<CmxIrohEndpointHealthEvent>.Continuation
    private var healthy = true
    private var closeCallCount = 0
    private var closeStarted = false
    private var closeStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var closeRelease: CheckedContinuation<Void, Never>?

    init(identity: CmxIrohPeerIdentity) {
        peerIdentity = identity
        let health = AsyncStream<CmxIrohEndpointHealthEvent>.makeStream()
        healthStream = health.stream
        healthContinuation = health.continuation
    }

    func identity() -> CmxIrohPeerIdentity { peerIdentity }

    func address() -> CmxIrohEndpointAddress {
        CmxIrohEndpointAddress(identity: peerIdentity, pathHints: [])
    }

    func connect(
        to _: CmxIrohEndpointAddress,
        alpn _: Data
    ) async throws -> any CmxIrohConnection {
        throw TestIrohTransportError.unsupported
    }

    func accept() async throws -> (any CmxIrohConnection)? { nil }

    func replaceRelays(_: [CmxIrohRelayConfiguration]) {}

    func healthEvents() -> AsyncStream<CmxIrohEndpointHealthEvent> { healthStream }

    func isHealthy() -> Bool { healthy }

    func close() async {
        closeCallCount += 1
        closeStarted = true
        let waiters = closeStartWaiters
        closeStartWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { closeRelease = $0 }
        healthContinuation.finish()
    }

    func setHealthy(_ value: Bool) { healthy = value }

    func waitForCloseStart() async {
        if closeStarted { return }
        await withCheckedContinuation { closeStartWaiters.append($0) }
    }

    func releaseClose() {
        closeRelease?.resume()
        closeRelease = nil
    }

    func observedCloseCallCount() -> Int { closeCallCount }
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
