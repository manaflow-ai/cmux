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
            credentialDidInstall: { response in
                await installs.record(response)
            }
        )

        try await coordinator.activate(
            bindingID: fixture.bindingID,
            endpointIdentity: fixture.identity,
            bootstrap: response
        )

        #expect(await clockEvents.next() == .sleep(fixture.refreshAfter))
        let updates = await endpoint.observedRelayUpdates()
        #expect(updates.count == 1)
        #expect(updates[0].map(\.url) == fixture.relayURLs)
        #expect(await coordinator.credentialExpiresAt() == fixture.expiresAt)
        #expect(await installs.values() == [response])
        #expect(await broker.observedBindingIDs().isEmpty)
        await coordinator.deactivate()
        #expect(await clockEvents.next() == .cancelled)
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
            jitter: { _, refreshAfter in refreshAfter }
        )

        try await coordinator.activate(
            bindingID: fixture.bindingID,
            endpointIdentity: fixture.identity
        )

        #expect(await clockEvents.next() == .sleep(fixture.refreshAfter))
        #expect(await broker.observedBindingIDs() == [fixture.bindingID])
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
            jitter: { _, refreshAfter in refreshAfter }
        )

        try await coordinator.activate(
            bindingID: fixture.bindingID,
            endpointIdentity: fixture.identity
        )

        #expect(await clockEvents.next() == .sleep(fixture.now.addingTimeInterval(60)))
        #expect(await broker.observedBindingIDs() == [fixture.bindingID])
        #expect(await endpoint.observedRelayUpdates().isEmpty)
        #expect(try await supervisor.activeEndpoint().identity() == fixture.identity)
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
            jitter: { _, refreshAfter in refreshAfter }
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

private actor TestRelayTokenBroker: CmxIrohRelayTokenServing {
    enum Step: Sendable {
        case response(CmxIrohRelayTokenResponse)
        case failure
    }

    private var steps: [Step]
    private var bindingIDs: [String] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    func issueRelayToken(bindingID: String) throws -> CmxIrohRelayTokenResponse {
        bindingIDs.append(bindingID)
        guard !steps.isEmpty else { throw TestRelayCoordinatorError.noResponse }
        switch steps.removeFirst() {
        case let .response(response):
            return response
        case .failure:
            throw TestRelayCoordinatorError.transient
        }
    }

    func observedBindingIDs() -> [String] {
        bindingIDs
    }
}

private final class TestRelayClock: CmxIrohRelayClock, @unchecked Sendable {
    enum Event: Equatable, Sendable {
        case sleep(Date)
        case cancelled
    }

    private let currentDate: Date
    private let eventStream: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    init(now: Date) {
        currentDate = now
        let events = AsyncStream<Event>.makeStream()
        eventStream = events.stream
        continuation = events.continuation
    }

    func now() -> Date {
        currentDate
    }

    func sleep(until deadline: Date) async throws {
        continuation.yield(.sleep(deadline))
        try await withTaskCancellationHandler {
            try await Task<Never, Never>.sleep(for: .seconds(24 * 60 * 60))
        } onCancel: {
            continuation.yield(.cancelled)
        }
    }

    func events() -> AsyncStream<Event> {
        eventStream
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
        relayURLs: [String]? = nil
    ) throws -> CmxIrohRelayTokenResponse {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let object: [String: Any] = [
            "token": "abc234",
            "expires_at": formatter.string(from: expiresAt),
            "refresh_after": formatter.string(from: refreshAfter),
            "relay_fleet": relayURLs ?? self.relayURLs,
        ]
        return try JSONDecoder().decode(
            CmxIrohRelayTokenResponse.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    }
}
