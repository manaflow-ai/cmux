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
        await installs.waitForCount(1)
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
    func requiredInitialCredentialWaitsThroughTransientMintFailure() async throws {
        let fixture = try RelayCoordinatorFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.identity)
        let supervisor = try await fixture.activeSupervisor(endpoint: endpoint)
        let broker = TestRelayTokenBroker(steps: [
            .failure,
            .response(try fixture.response()),
        ])
        let clock = TestRelayClock(now: fixture.now)
        var clockEvents = clock.events().makeAsyncIterator()
        let completions = TestRelayActivationCompletionRecorder()
        let installs = TestRelayCredentialInstallRecorder()
        let coordinator = CmxIrohRelayCredentialCoordinator(
            supervisor: supervisor,
            broker: broker,
            managedRelayURLs: Set(fixture.relayURLs),
            clock: clock,
            jitter: { _, refreshAfter in refreshAfter },
            retrySchedule: CmxIrohRetrySchedule(
                initialDelay: 1,
                maximumDelay: 1,
                jitterFraction: 0
            ),
            retryJitter: { 0 },
            credentialDidInstall: { response in
                await installs.record(response)
            }
        )
        let activation = Task {
            try await coordinator.activate(
                bindingID: fixture.bindingID,
                endpointIdentity: fixture.identity,
                waitForInitialCredential: true
            )
            await completions.record()
        }

        guard case let .sleep(deadline) = await clockEvents.next() else {
            Issue.record("Expected the initial relay retry sleep")
            return
        }
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(deadline == fixture.now.addingTimeInterval(1))
        #expect(await completions.count() == 0)

        clock.advance(to: deadline)
        try await activation.value
        await installs.waitForCount(1)
        #expect(await completions.count() == 1)
        #expect(await broker.observedEndpointIDs() == [fixture.identity, fixture.identity])
        #expect(await endpoint.observedRelayUpdates().count == 1)
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

        let clockEvent = await clockEvents.next()
        #expect(await endpoint.observedRelayUpdates().isEmpty)
        #expect(clockEvent == .sleep(fixture.now.addingTimeInterval(600)))
        await coordinator.deactivate()
    }

}

private actor TestRelayActivationCompletionRecorder {
    private var completionCount = 0

    func record() {
        completionCount += 1
    }

    func count() -> Int {
        completionCount
    }
}

private actor TestRelayCredentialInstallRecorder {
    private var responses: [CmxIrohRelayTokenResponse] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func record(_ response: CmxIrohRelayTokenResponse) {
        responses.append(response)
        let ready = waiters.filter { responses.count >= $0.0 }
        waiters.removeAll { responses.count >= $0.0 }
        for (_, continuation) in ready { continuation.resume() }
    }

    func values() -> [CmxIrohRelayTokenResponse] {
        responses
    }

    func waitForCount(_ count: Int) async {
        guard responses.count < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
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

actor TestRelayTokenBroker: CmxIrohRelayTokenServing {
    enum Step: Sendable {
        case response(CmxIrohRelayTokenResponse)
        case failure
        case rateLimited(Int)
    }

    private var steps: [Step]
    private var endpointIDs: [CmxIrohPeerIdentity] = []
    private var issueCount = 0
    private let issueHook: (@Sendable (_ count: Int) async -> Void)?

    init(
        steps: [Step],
        issueHook: (@Sendable (_ count: Int) async -> Void)? = nil
    ) {
        self.steps = steps
        self.issueHook = issueHook
    }

    func issueRelayToken(
        bindingID _: String,
        endpointID: CmxIrohPeerIdentity
    ) async throws -> CmxIrohRelayTokenResponse {
        endpointIDs.append(endpointID)
        issueCount += 1
        await issueHook?(issueCount)
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

final class TestRelayClock: CmxIrohRelayClock, @unchecked Sendable {
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

    func setNowWithoutResuming(_ date: Date) {
        lock.withLock { currentDate = date }
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

struct RelayCoordinatorFixture: Sendable {
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
