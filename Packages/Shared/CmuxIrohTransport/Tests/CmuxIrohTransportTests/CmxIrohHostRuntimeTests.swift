import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohHostRuntimeTests {
    @Test("direct-only startup does not wait for relay readiness")
    func directOnlyStartupSkipsRelayReadiness() async throws {
        let fixture = try HostRuntimeFixture()
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery
        )
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(
                endpoints: [TestIrohEndpoint(identity: fixture.endpointID)]
            ),
            broker: broker,
            configuration: fixture.configuration(
                endpointRelayProfile: .unavailableManagedSelection
            ),
            pendingRevocations: fixture.pendingRevocations(),
            protocolConfiguration: .testDirectOnlyApplicationLanes,
            handleTransport: { session, _ in await session.close() }
        )

        try await runtime.start()

        #expect(await runtime.snapshot().state == .active)
        #expect(await broker.observedRelayIssueCount() == 0)
        await runtime.stop()
    }

    @Test("cold start retries transient broker connectivity before becoming active")
    func coldStartRetriesTransientBrokerConnectivity() async throws {
        let fixture = try HostRuntimeFixture()
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            registrationError: .connectivity
        )
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(
                endpoints: [TestIrohEndpoint(identity: fixture.endpointID)]
            ),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            registrationClock: ImmediateHostActivationClock(),
            registrationRetrySchedule: CmxIrohRetrySchedule(
                initialDelay: 1,
                maximumDelay: 1,
                jitterFraction: 0
            ),
            registrationRetryJitter: { 0 },
            handleTransport: { session, _ in await session.close() }
        )

        try await runtime.start()

        #expect(await broker.observedRegistrationCount() == 2)
        #expect(await runtime.snapshot().state == .active)
        await runtime.stop()
    }

    @Test("cold start retries transient broker service failures before becoming active")
    func coldStartRetriesTransientBrokerServiceFailure() async throws {
        let fixture = try HostRuntimeFixture()
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            registrationError: .rejected(statusCode: 503, code: "unavailable")
        )
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(
                endpoints: [TestIrohEndpoint(identity: fixture.endpointID)]
            ),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            registrationClock: ImmediateHostActivationClock(),
            registrationRetrySchedule: CmxIrohRetrySchedule(
                initialDelay: 1,
                maximumDelay: 1,
                jitterFraction: 0
            ),
            registrationRetryJitter: { 0 },
            handleTransport: { session, _ in await session.close() }
        )

        try await runtime.start()

        #expect(await broker.observedRegistrationCount() == 2)
        #expect(await runtime.snapshot().state == .active)
        await runtime.stop()
    }

    @Test("cold start does not retry an untrusted broker response")
    func coldStartDoesNotRetryInvalidBrokerResponse() async throws {
        let fixture = try HostRuntimeFixture()
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            registrationError: .invalidResponse
        )
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(
                endpoints: [TestIrohEndpoint(identity: fixture.endpointID)]
            ),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            registrationClock: ImmediateHostActivationClock(),
            handleTransport: { session, _ in await session.close() }
        )

        await #expect(throws: CmxIrohTrustBrokerClientError.invalidResponse) {
            try await runtime.start()
        }

        #expect(await broker.observedRegistrationCount() == 1)
        #expect(await runtime.snapshot().state == .failed)
    }

    @Test("stopping during cold-start backoff prevents a stale registration retry")
    func stopDuringColdStartBackoffPreventsRetry() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try HostRuntimeFixture(now: now)
        let clock = HostRegistrationRenewalClock(now: now)
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            registrationError: .connectivity
        )
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(
                endpoints: [TestIrohEndpoint(identity: fixture.endpointID)]
            ),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            registrationClock: clock,
            registrationRetrySchedule: CmxIrohRetrySchedule(
                initialDelay: 1,
                maximumDelay: 1,
                jitterFraction: 0
            ),
            registrationRetryJitter: { 0 },
            handleTransport: { session, _ in await session.close() }
        )
        let start = Task {
            try await runtime.start()
        }

        await clock.waitUntilSleeping()
        let deadline = try #require(clock.observedSleepDeadlines().first)
        await runtime.stop()
        clock.advance(to: deadline)

        await #expect(throws: CmxIrohHostRuntimeError.superseded) {
            try await start.value
        }
        #expect(await broker.observedRegistrationCount() == 1)
        #expect(await runtime.snapshot().state == .inactive)
    }

    @Test("cancelling cold-start backoff cancels its delay and closes the endpoint")
    func cancellingColdStartBackoffCancelsDelay() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try HostRuntimeFixture(now: now)
        let clock = HostRegistrationRenewalClock(now: now)
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            registrationError: .connectivity
        )
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            registrationClock: clock,
            registrationRetrySchedule: CmxIrohRetrySchedule(
                initialDelay: 7,
                maximumDelay: 7,
                jitterFraction: 0
            ),
            registrationRetryJitter: { 0 },
            handleTransport: { session, _ in await session.close() }
        )
        let start = Task {
            try await runtime.start()
        }

        await clock.waitUntilSleeping()
        #expect(clock.observedSleepDeadlines() == [now.addingTimeInterval(7)])
        start.cancel()

        await #expect(throws: CancellationError.self) {
            try await start.value
        }
        #expect(clock.observedCancellationCount() == 1)
        #expect(await broker.observedRegistrationCount() == 1)
        #expect(await endpoint.observedCloseCallCount() == 1)
        #expect(await runtime.snapshot().state == .failed)
    }

    @Test
    func pendingRevocationFailureBlocksHostRegistrationAndCachedFallback() async throws {
        let fixture = try HostRuntimeFixture()
        let pendingRevocations = CmxIrohPendingRevocationOutbox(
            secureStore: TestSecureCredentialStore()
        )
        let pending = try CmxIrohPendingRevocation(
            accountID: fixture.configuration.accountID,
            tag: "older-build",
            bindingID: "123e4567-e89b-42d3-a456-426614174099"
        )
        try await pendingRevocations.enqueue(pending)
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            revokeError: .connectivity
        )
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(
                endpoints: [TestIrohEndpoint(identity: fixture.endpointID)]
            ),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: pendingRevocations,
            handleTransport: { session, _ in await session.close() }
        )

        await #expect(throws: CmxIrohTrustBrokerClientError.connectivity) {
            try await runtime.start()
        }

        #expect(await broker.observedRegistrationCount() == 0)
        #expect(await broker.observedRevokedBindingIDs() == [pending.bindingID])
        #expect(
            try await pendingRevocations.pending(
                accountID: fixture.configuration.accountID
            ) == [pending]
        )
    }

}

actor TestIrohHostBroker: CmxIrohHostBrokerServing {
    private var registrationBindings: [CmxIrohBrokerBinding]
    private var discoveryResponses: [CmxIrohDiscoveryResponse]
    private let registrationError: CmxIrohTrustBrokerClientError?
    private let discoveryError: CmxIrohTrustBrokerClientError?
    private let revokeError: CmxIrohTrustBrokerClientError?
    private let registrationHook: (@Sendable () async -> Bool)?
    private let subsequentRegistrationHook: (@Sendable () async -> Void)?
    private let relayIssueHook: (@Sendable () async -> Void)?
    private var subsequentRegistrationErrors: [CmxIrohTrustBrokerClientError]
    private var registrationCount = 0
    private var preparedRegistrations: [CmxIrohPreparedRegistration] = []
    private var relayIssueCount = 0
    private var registrationHookResult: Bool?
    private var revokedBindingIDs: [String] = []
    private var registrationCountWaiters: [
        UUID: (minimum: Int, continuation: CheckedContinuation<Void, Never>)
    ] = [:]

    init(
        registrationBinding: CmxIrohBrokerBinding,
        discovery: CmxIrohDiscoveryResponse,
        subsequentRegistrationBindings: [CmxIrohBrokerBinding] = [],
        subsequentDiscoveries: [CmxIrohDiscoveryResponse] = [],
        registrationError: CmxIrohTrustBrokerClientError? = nil,
        discoveryError: CmxIrohTrustBrokerClientError? = nil,
        revokeError: CmxIrohTrustBrokerClientError? = nil,
        registrationHook: (@Sendable () async -> Bool)? = nil,
        subsequentRegistrationHook: (@Sendable () async -> Void)? = nil,
        relayIssueHook: (@Sendable () async -> Void)? = nil,
        subsequentRegistrationErrors: [CmxIrohTrustBrokerClientError] = []
    ) {
        registrationBindings = [registrationBinding] + subsequentRegistrationBindings
        discoveryResponses = [discovery] + subsequentDiscoveries
        self.registrationError = registrationError
        self.discoveryError = discoveryError
        self.revokeError = revokeError
        self.registrationHook = registrationHook
        self.subsequentRegistrationHook = subsequentRegistrationHook
        self.relayIssueHook = relayIssueHook
        self.subsequentRegistrationErrors = subsequentRegistrationErrors
    }

    func register(
        prepared: CmxIrohPreparedRegistration,
        signer _: CmxIrohRegistrationSigner
    ) async throws -> CmxIrohRegistrationResponse {
        registrationCount += 1
        preparedRegistrations.append(prepared)
        let readyIDs = registrationCountWaiters.compactMap { id, waiter in
            registrationCount >= waiter.minimum ? id : nil
        }
        for id in readyIDs {
            registrationCountWaiters.removeValue(forKey: id)?.continuation.resume()
        }
        if registrationCount == 1, let registrationError {
            throw registrationError
        }
        if registrationCount > 1, !subsequentRegistrationErrors.isEmpty {
            throw subsequentRegistrationErrors.removeFirst()
        }
        if registrationCount > 1, let subsequentRegistrationHook {
            await subsequentRegistrationHook()
        }
        if let registrationHook {
            registrationHookResult = await registrationHook()
        }
        let binding = registrationBindings.count > 1
            ? registrationBindings.removeFirst()
            : registrationBindings[0]
        return CmxIrohRegistrationResponse(
            binding: binding,
            relay: .unavailable
        )
    }

    func discover() throws -> CmxIrohDiscoveryResponse {
        if let discoveryError { throw discoveryError }
        guard discoveryResponses.count > 1 else {
            return discoveryResponses[0]
        }
        return discoveryResponses.removeFirst()
    }

    func issueEndpointAttestation(
        bindingID _: String
    ) throws -> CmxIrohEndpointAttestationResponse {
        throw TestIrohTransportError.unsupported
    }

    func issueRelayToken(
        bindingID _: String,
        endpointID _: CmxIrohPeerIdentity
    ) async -> CmxIrohRelayTokenResponse {
        relayIssueCount += 1
        if let relayIssueHook {
            await relayIssueHook()
        }
        return CmxIrohRelayTokenResponse(
            token: "testrelaytoken",
            expiresAt: "2027-07-10T12:00:00.000Z",
            refreshAfter: "2027-07-10T11:00:00.000Z",
            relayFleet: HostRuntimeFixture.relayURLs
        )
    }

    func revoke(bindingID: String) throws {
        revokedBindingIDs.append(bindingID)
        if let revokeError { throw revokeError }
    }

    func observedRegistrationCount() -> Int { registrationCount }
    func observedPreparedRegistrations() -> [CmxIrohPreparedRegistration] {
        preparedRegistrations
    }
    func observedRelayIssueCount() -> Int { relayIssueCount }

    func enqueueSubsequentRegistrationError(
        _ error: CmxIrohTrustBrokerClientError
    ) {
        subsequentRegistrationErrors.append(error)
    }

    func waitForRegistrationCount(_ minimum: Int) async {
        if registrationCount >= minimum { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    registrationCountWaiters[id] = (minimum, continuation)
                }
            }
        } onCancel: {
            Task { await self.cancelRegistrationWaiter(id) }
        }
    }

    func waitForRegistrationCount(_ minimum: Int, timeout: Duration) async -> Bool {
        if registrationCount >= minimum { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.waitForRegistrationCount(minimum)
                return !Task.isCancelled
            }
            group.addTask {
                do {
                    try await ContinuousClock().sleep(for: timeout)
                } catch {
                    return false
                }
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func cancelRegistrationWaiter(_ id: UUID) {
        registrationCountWaiters.removeValue(forKey: id)?.continuation.resume()
    }

    func observedRegistrationHookResult() -> Bool? { registrationHookResult }
    func observedRevokedBindingIDs() -> [String] { revokedBindingIDs }
}

actor HostRuntimeBindingRecorder {
    private var recordedCount = 0

    func record() { recordedCount += 1 }
    func count() -> Int { recordedCount }
}

actor HostRuntimeLANRefreshRecorder {
    private var recordedCount = 0
    private var waiters: [
        UUID: (minimum: Int, continuation: CheckedContinuation<Void, Never>)
    ] = [:]

    func record() {
        recordedCount += 1
        let readyIDs = waiters.compactMap { id, waiter in
            recordedCount >= waiter.minimum ? id : nil
        }
        for id in readyIDs {
            waiters.removeValue(forKey: id)?.continuation.resume()
        }
    }

    func waitForRefresh(timeout: Duration) async -> Bool {
        await waitForCount(1, timeout: timeout)
    }

    func waitForCount(_ count: Int, timeout: Duration) async -> Bool {
        if recordedCount >= count { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.waitForCount(count)
                return true
            }
            group.addTask {
                do {
                    // A bounded test deadline prevents a missing lifecycle signal from hanging CI.
                    try await ContinuousClock().sleep(for: timeout)
                } catch {}
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    func count() -> Int { recordedCount }

    private func waitForCount(_ count: Int) async {
        if recordedCount >= count { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[id] = (count, continuation)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume()
    }
}

actor HostRuntimeRegistrationGate {
    private var shouldBlock = true
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?

    func waitOnce() async {
        guard shouldBlock else { return }
        shouldBlock = false
        guard !opened else { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func open() {
        opened = true
        waiter?.resume()
        waiter = nil
    }
}

actor HostRuntimeLANPolicyRecorder {
    private var recordedContexts: [CmxIrohHostLANAdvertisementContext] = []
    private var recordedAddresses: [[String]] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record(
        context: CmxIrohHostLANAdvertisementContext,
        directAddresses: [String]
    ) {
        recordedContexts.append(context)
        recordedAddresses.append(directAddresses)
        let ready = waiters.filter { recordedContexts.count >= $0.count }
        waiters.removeAll { recordedContexts.count >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
    }

    func contexts() -> [CmxIrohHostLANAdvertisementContext] { recordedContexts }
    func addresses() -> [[String]] { recordedAddresses }

    func waitForCount(_ count: Int) async {
        if recordedContexts.count >= count { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }
}

actor HostRuntimeSignOutOrderingRecorder {
    private var recorded: [String] = []

    func record(endpointClosed: Bool, revocationQueued: Bool) {
        recorded.append("\(endpointClosed):\(revocationQueued)")
    }

    func values() -> [String] { recorded }
}

actor HostRuntimeAcceptingEndpoint: CmxIrohEndpoint {
    private let peerIdentity: CmxIrohPeerIdentity
    private var connections: [any CmxIrohConnection] = []
    private var waiters: [
        UUID: CheckedContinuation<(any CmxIrohConnection)?, Never>
    ] = [:]
    private let health: AsyncStream<CmxIrohEndpointHealthEvent>
    private let healthContinuation: AsyncStream<CmxIrohEndpointHealthEvent>.Continuation
    private var closed = false
    private var closeCallCount = 0

    init(identity: CmxIrohPeerIdentity) {
        peerIdentity = identity
        let stream = AsyncStream<CmxIrohEndpointHealthEvent>.makeStream()
        health = stream.stream
        healthContinuation = stream.continuation
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

    func accept() async throws -> (any CmxIrohConnection)? {
        try Task.checkCancellation()
        if !connections.isEmpty { return connections.removeFirst() }
        guard !closed else { return nil }
        let id = UUID()
        let connection = await withTaskCancellationHandler {
            await withCheckedContinuation { waiters[id] = $0 }
        } onCancel: {
            Task { await self.cancelAccept(id) }
        }
        try Task.checkCancellation()
        return connection
    }

    func replaceRelays(_: [CmxIrohRelayConfiguration]) {}
    func healthEvents() -> AsyncStream<CmxIrohEndpointHealthEvent> { health }
    func isHealthy() -> Bool { true }

    func close() {
        closed = true
        closeCallCount += 1
        let pending = waiters.values
        waiters.removeAll()
        for continuation in pending { continuation.resume(returning: nil) }
        healthContinuation.finish()
    }

    func enqueue(_ connection: any CmxIrohConnection) {
        if let id = waiters.keys.first,
           let continuation = waiters.removeValue(forKey: id) {
            continuation.resume(returning: connection)
        } else {
            connections.append(connection)
        }
    }

    func observedCloseCallCount() -> Int { closeCallCount }

    private func cancelAccept(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: nil)
    }
}
