import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohRelayCredentialCoordinatorTests {
    @Test
    func bootstrapInstallsCompleteFleetBeforeSleepingUntilRefresh() async throws {
        let fixture = try RelayCoordinatorFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.identity)
        let supervisor = try await fixture.activeSupervisor(endpoint: endpoint)
        let broker = TestRelayTokenBroker(steps: [])
        let clock = TestRelayClock(now: fixture.now)
        var clockEvents = clock.events().makeAsyncIterator()
        let response = try fixture.response()
        let installs = TestRelayCredentialInstallRecorder()
        let coordinator = CmxIrohRelayCredentialCoordinator(
            supervisor: supervisor,
            broker: broker,
            managedRelayURLs: Set(fixture.relayURLs),
            clock: clock,
            jitter: { _, refreshAfter in refreshAfter },
            retryJitter: { 0 },
            credentialDidInstall: { response in
                await installs.record(response)
            }
        )

        try await coordinator.activate(
            bindingID: fixture.bindingID,
            endpointIdentity: fixture.identity,
            bootstrap: response
        )

        guard case let .sleep(deadline) = await clockEvents.next() else {
            Issue.record("Expected the relay refresh sleep")
            return
        }
        #expect(deadline == fixture.refreshAfter)
        let updates = await endpoint.observedRelayUpdates()
        #expect(updates.count == 1)
        #expect(updates[0].map(\.url) == fixture.relayURLs)
        #expect(await coordinator.credentialExpiresAt() == fixture.expiresAt)
        #expect(await installs.values() == [response])
        #expect(await broker.observedEndpointIDs().isEmpty)
        await coordinator.deactivate()
        #expect(await clockEvents.next() == .cancelled)
    }

    @Test
    func stalledCredentialPersistenceDoesNotBlockRefreshScheduling() async throws {
        let fixture = try RelayCoordinatorFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.identity)
        let supervisor = try await fixture.activeSupervisor(endpoint: endpoint)
        let clock = TestRelayClock(now: fixture.now)
        let persistence = TestRelayCredentialPersistenceGate()
        let coordinator = CmxIrohRelayCredentialCoordinator(
            supervisor: supervisor,
            broker: TestRelayTokenBroker(steps: []),
            managedRelayURLs: Set(fixture.relayURLs),
            clock: clock,
            jitter: { _, refreshAfter in refreshAfter },
            retryJitter: { 0 },
            credentialDidInstall: { response in
                await persistence.persist(response)
            }
        )

        let activation = Task {
            try await coordinator.activate(
                bindingID: fixture.bindingID,
                endpointIdentity: fixture.identity,
                bootstrap: try fixture.response()
            )
        }
        await persistence.waitUntilStarted()
        for _ in 0 ..< 20 { await Task.yield() }

        #expect(clock.observedSleepDeadlines() == [fixture.refreshAfter])
        #expect(await endpoint.observedRelayUpdates().count == 1)

        await persistence.resume()
        try await activation.value
        await coordinator.deactivate()
    }

    @Test
    func bootstrapKeepsEachTokenAssociatedWithItsSignedRelayURL() async throws {
        let fixture = try RelayCoordinatorFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.identity)
        let supervisor = try await fixture.activeSupervisor(endpoint: endpoint)
        let coordinator = CmxIrohRelayCredentialCoordinator(
            supervisor: supervisor,
            broker: TestRelayTokenBroker(steps: []),
            managedRelayURLs: Set(fixture.relayURLs),
            clock: TestRelayClock(now: fixture.now),
            jitter: { _, refreshAfter in refreshAfter },
            retryJitter: { 0 }
        )

        try await coordinator.activate(
            bindingID: fixture.bindingID,
            endpointIdentity: fixture.identity,
            bootstrap: try fixture.response(tokens: ["abc234", "def567"])
        )

        let updates = await endpoint.observedRelayUpdates()
        #expect(updates.count == 1)
        #expect(updates[0].map(\.url) == fixture.relayURLs)
        #expect(updates[0].map(\.token) == ["abc234", "def567"])
        await coordinator.deactivate()
    }

    @Test
    func selectedManagedSubsetInstallsOnlyChosenRelayAfterFullFleetValidation() async throws {
        let fixture = try RelayCoordinatorFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.identity)
        let supervisor = try await fixture.activeSupervisor(endpoint: endpoint)
        let clock = TestRelayClock(now: fixture.now)
        let selectedURL = fixture.relayURLs[1]
        let coordinator = CmxIrohRelayCredentialCoordinator(
            supervisor: supervisor,
            broker: TestRelayTokenBroker(steps: []),
            managedRelayURLs: Set(fixture.relayURLs),
            selectedRelayURLs: [selectedURL],
            clock: clock,
            jitter: { _, refreshAfter in refreshAfter },
            retryJitter: { 0 }
        )

        try await coordinator.activate(
            bindingID: fixture.bindingID,
            endpointIdentity: fixture.identity,
            bootstrap: try fixture.response()
        )

        let profiles = await endpoint.observedRelayProfileUpdates()
        #expect(profiles.count == 1)
        #expect(profiles[0].allowedRelayURLs == [selectedURL])
        #expect(profiles[0].managedRelays.map(\.url) == [selectedURL])
        #expect(await endpoint.observedRelayUpdates().isEmpty)
        await coordinator.deactivate()
    }

    @Test
    func missingBootstrapRefreshesImmediatelyAndInstallsWithoutRebinding() async throws {
        let fixture = try RelayCoordinatorFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.identity)
        let supervisor = try await fixture.activeSupervisor(endpoint: endpoint)
        let broker = TestRelayTokenBroker(steps: [.response(try fixture.response())])
        let clock = TestRelayClock(now: fixture.now)
        var clockEvents = clock.events().makeAsyncIterator()
        let coordinator = CmxIrohRelayCredentialCoordinator(
            supervisor: supervisor,
            broker: broker,
            managedRelayURLs: Set(fixture.relayURLs),
            clock: clock,
            jitter: { _, refreshAfter in refreshAfter },
            retryJitter: { 0 }
        )

        try await coordinator.activate(
            bindingID: fixture.bindingID,
            endpointIdentity: fixture.identity
        )

        guard case let .sleep(deadline) = await clockEvents.next() else {
            Issue.record("Expected the relay refresh sleep")
            return
        }
        #expect(deadline == fixture.refreshAfter)
        #expect(await broker.observedEndpointIDs() == [fixture.identity])
        #expect(await endpoint.observedRelayUpdates().count == 1)
        #expect(try await supervisor.activeEndpoint().identity() == fixture.identity)
        await coordinator.deactivate()
    }

    @Test
    func transientMintFailureKeepsEndpointAliveAndBacksOff() async throws {
        let fixture = try RelayCoordinatorFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.identity)
        let supervisor = try await fixture.activeSupervisor(endpoint: endpoint)
        let broker = TestRelayTokenBroker(steps: [.failure])
        let clock = TestRelayClock(now: fixture.now)
        var clockEvents = clock.events().makeAsyncIterator()
        let coordinator = CmxIrohRelayCredentialCoordinator(
            supervisor: supervisor,
            broker: broker,
            managedRelayURLs: Set(fixture.relayURLs),
            clock: clock,
            jitter: { _, refreshAfter in refreshAfter },
            retryJitter: { 0 }
        )

        try await coordinator.activate(
            bindingID: fixture.bindingID,
            endpointIdentity: fixture.identity
        )

        guard case let .sleep(deadline) = await clockEvents.next() else {
            Issue.record("Expected the relay retry sleep")
            return
        }
        #expect(deadline == fixture.now.addingTimeInterval(30))
        #expect(await broker.observedEndpointIDs() == [fixture.identity])
        #expect(await endpoint.observedRelayUpdates().isEmpty)
        #expect(try await supervisor.activeEndpoint().identity() == fixture.identity)
        await coordinator.deactivate()
    }

    @Test
    func rateLimitRetryNeverPrecedesValidatedServerFloor() async throws {
        let fixture = try RelayCoordinatorFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.identity)
        let supervisor = try await fixture.activeSupervisor(endpoint: endpoint)
        let clock = TestRelayClock(now: fixture.now)
        var clockEvents = clock.events().makeAsyncIterator()
        let coordinator = CmxIrohRelayCredentialCoordinator(
            supervisor: supervisor,
            broker: TestRelayTokenBroker(steps: [.rateLimited(600)]),
            managedRelayURLs: Set(fixture.relayURLs),
            clock: clock,
            jitter: { _, refreshAfter in refreshAfter },
            retryJitter: { 0 }
        )

        try await coordinator.activate(
            bindingID: fixture.bindingID,
            endpointIdentity: fixture.identity
        )

        #expect(
            await clockEvents.next()
                == .sleep(fixture.now.addingTimeInterval(600))
        )
        #expect(await endpoint.observedRelayUpdates().isEmpty)
        await coordinator.deactivate()
    }

    @Test
    func refreshFailureRetriesBeforeInstalledCredentialSafetyDeadline() async throws {
        let fixture = try RelayCoordinatorFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.identity)
        let supervisor = try await fixture.activeSupervisor(endpoint: endpoint)
        let broker = TestRelayTokenBroker(steps: [.failure])
        let clock = TestRelayClock(now: fixture.now)
        var clockEvents = clock.events().makeAsyncIterator()
        let expiresAt = fixture.now.addingTimeInterval(5 * 60)
        let refreshAfter = expiresAt.addingTimeInterval(-60)
        let coordinator = CmxIrohRelayCredentialCoordinator(
            supervisor: supervisor,
            broker: broker,
            managedRelayURLs: Set(fixture.relayURLs),
            clock: clock,
            jitter: { _, refreshAfter in refreshAfter },
            retryJitter: { 0 }
        )

        try await coordinator.activate(
            bindingID: fixture.bindingID,
            endpointIdentity: fixture.identity,
            bootstrap: try fixture.response(
                refreshAfter: refreshAfter,
                expiresAt: expiresAt
            )
        )
        #expect(await clockEvents.next() == .sleep(refreshAfter))

        clock.advance(to: refreshAfter)

        guard case let .sleep(retryDeadline) = await clockEvents.next() else {
            Issue.record("Expected a relay retry before credential expiry")
            return
        }
        #expect(retryDeadline == expiresAt.addingTimeInterval(-30))
        #expect(retryDeadline < expiresAt)
        #expect(await broker.observedEndpointIDs() == [fixture.identity])
        await coordinator.deactivate()
    }

    @Test
    func mismatchedBootstrapFleetNeverMutatesEndpoint() async throws {
        let fixture = try RelayCoordinatorFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.identity)
        let supervisor = try await fixture.activeSupervisor(endpoint: endpoint)
        let coordinator = CmxIrohRelayCredentialCoordinator(
            supervisor: supervisor,
            broker: TestRelayTokenBroker(steps: [.failure]),
            managedRelayURLs: Set(fixture.relayURLs),
            clock: TestRelayClock(now: fixture.now),
            jitter: { _, refreshAfter in refreshAfter },
            retryJitter: { 0 }
        )
        let incomplete = try fixture.response(relayURLs: [fixture.relayURLs[0]])

        await #expect(
            throws: CmxIrohRelayCredentialCoordinatorError.relayFleetMismatch
        ) {
            try await coordinator.activate(
                bindingID: fixture.bindingID,
                endpointIdentity: fixture.identity,
                bootstrap: incomplete
            )
        }
        await coordinator.deactivate()

        #expect(await endpoint.observedRelayUpdates().isEmpty)
        #expect(try await supervisor.activeEndpoint().identity() == fixture.identity)
    }
}

private actor TestRelayCredentialInstallRecorder {
    private var responses: [CmxIrohRelayTokenResponse] = []

    func record(_ response: CmxIrohRelayTokenResponse) {
        responses.append(response)
    }

    func values() -> [CmxIrohRelayTokenResponse] {
        responses
    }
}

private actor TestRelayCredentialPersistenceGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var persistenceContinuation: CheckedContinuation<Void, Never>?

    func persist(_: CmxIrohRelayTokenResponse) async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            persistenceContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resume() {
        persistenceContinuation?.resume()
        persistenceContinuation = nil
    }
}

private actor TestRelayTokenBroker: CmxIrohRelayTokenServing {
    enum Step: Sendable {
        case response(CmxIrohRelayTokenResponse)
        case failure
        case rateLimited(Int)
    }

    private var steps: [Step]
    private var endpointIDs: [CmxIrohPeerIdentity] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    func issueRelayToken(
        bindingID _: String,
        endpointID: CmxIrohPeerIdentity
    ) throws -> CmxIrohRelayTokenResponse {
        endpointIDs.append(endpointID)
        guard !steps.isEmpty else { throw TestRelayCoordinatorError.noResponse }
        switch steps.removeFirst() {
        case let .response(response):
            return response
        case .failure:
            throw TestRelayCoordinatorError.transient
        case let .rateLimited(retryAfterSeconds):
            throw CmxIrohTrustBrokerClientError.rateLimited(
                code: "rate_limited",
                retryAfterSeconds: retryAfterSeconds
            )
        }
    }

    func observedEndpointIDs() -> [CmxIrohPeerIdentity] {
        endpointIDs
    }
}

private final class TestRelayClock: CmxIrohRelayClock, @unchecked Sendable {
    enum Event: Equatable, Sendable {
        case sleep(Date)
        case cancelled
    }

    private let lock = NSLock()
    private var currentDate: Date
    private var sleepers: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var sleepDeadlines: [Date] = []
    private let eventStream: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    init(now: Date) {
        currentDate = now
        let events = AsyncStream<Event>.makeStream()
        eventStream = events.stream
        continuation = events.continuation
    }

    func now() -> Date {
        lock.withLock { currentDate }
    }

    func sleep(until deadline: Date) async throws {
        lock.withLock { sleepDeadlines.append(deadline) }
        continuation.yield(.sleep(deadline))
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { sleeper in
                lock.withLock {
                    sleepers[id] = sleeper
                }
                if Task.isCancelled {
                    cancelSleep(id: id)
                }
            }
        } onCancel: {
            cancelSleep(id: id)
        }
    }

    func advance(to date: Date) {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            currentDate = date
            defer { sleepers.removeAll() }
            return Array(sleepers.values)
        }
        for sleeper in pending {
            sleeper.resume()
        }
    }

    func events() -> AsyncStream<Event> {
        eventStream
    }

    func observedSleepDeadlines() -> [Date] {
        lock.withLock { sleepDeadlines }
    }

    private func cancelSleep(id: UUID) {
        let sleeper = lock.withLock { sleepers.removeValue(forKey: id) }
        guard let sleeper else { return }
        continuation.yield(.cancelled)
        sleeper.resume(throwing: CancellationError())
    }
}

private enum TestRelayCoordinatorError: Error {
    case noResponse
    case transient
}

private struct RelayCoordinatorFixture: Sendable {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let bindingID = "123e4567-e89b-42d3-a456-426614174010"
    let identity: CmxIrohPeerIdentity
    let relayURLs = [
        "https://use1-1.relay.lawrence.cmux.iroh.link/",
        "https://usw1-1.relay.lawrence.cmux.iroh.link/",
    ]

    var refreshAfter: Date {
        now.addingTimeInterval(12 * 60 * 60)
    }

    var expiresAt: Date {
        now.addingTimeInterval(24 * 60 * 60)
    }

    init() throws {
        identity = try CmxIrohPeerIdentity(endpointID: String(repeating: "ab", count: 32))
    }

    func activeSupervisor(
        endpoint: TestIrohEndpoint
    ) async throws -> CmxIrohEndpointSupervisor {
        let supervisor = CmxIrohEndpointSupervisor(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            configuration: try CmxIrohEndpointConfiguration(
                secretKey: CmxIrohSecretKey(bytes: Data(repeating: 7, count: 32)),
                alpns: [CmxIrohProtocolConfiguration.cmuxMobileV1.alpn],
                managedRelayURLs: Set(relayURLs),
                relays: []
            )
        )
        _ = try await supervisor.activate()
        return supervisor
    }

    func response(
        relayURLs: [String]? = nil,
        tokens: [String]? = nil,
        refreshAfter: Date? = nil,
        expiresAt: Date? = nil
    ) throws -> CmxIrohRelayTokenResponse {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let urls = relayURLs ?? self.relayURLs
        if let tokens {
            guard tokens.count == urls.count else {
                throw CmxIrohTrustBrokerClientError.invalidResponse
            }
            return CmxIrohRelayTokenResponse(
                credentials: zip(urls, tokens).map { url, token in
                    CmxIrohManagedRelayCredential(
                        relayURL: url,
                        token: token,
                        expiresAt: formatter.string(
                            from: expiresAt ?? self.expiresAt
                        ),
                        refreshAfter: formatter.string(
                            from: refreshAfter ?? self.refreshAfter
                        )
                    )
                }
            )
        }
        let object: [String: Any] = [
            "token": "abc234",
            "expires_at": formatter.string(from: expiresAt ?? self.expiresAt),
            "refresh_after": formatter.string(from: refreshAfter ?? self.refreshAfter),
            "relay_fleet": urls,
        ]
        return try JSONDecoder().decode(
            CmxIrohRelayTokenResponse.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    }
}
