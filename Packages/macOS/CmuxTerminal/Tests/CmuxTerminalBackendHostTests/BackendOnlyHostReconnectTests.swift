import CmuxTerminalBackend
@testable import CmuxTerminalBackendHost
import Foundation
import Testing

@Suite("Backend-only host reconnect lifecycle")
@MainActor
struct BackendOnlyHostReconnectTests {
    @Test("projection claim failure invalidates the candidate before retrying")
    func projectionClaimFailureInvalidatesCandidateBeforeRetrying() async throws {
        let first = try BackendOnlyHostConnectionFixture.make(number: 1)
        let second = try BackendOnlyHostConnectionFixture.make(number: 2)
        let controller = FakeBackendOnlyHostController(
            outcomes: [.connection(first), .connection(second)],
            projectionFailures: [1]
        )
        var observations = await controller.observations().makeAsyncIterator()
        let model = makeModel(controller: controller, maximumConnectionAttempts: 2)

        model.start()

        #expect(await observations.next() == .connectAttempt(1))
        #expect(await observations.next() == .projectionClaim(1))
        #expect(await observations.next() == .invalidated(1))
        #expect(await observations.next() == .connectAttempt(2))
        #expect(await observations.next() == .projectionClaim(2))
        #expect(await observations.next() == .eventSubscription(2))
        await model.awaitCurrentConnectionCycle()

        #expect(model.phase == .ready)
        #expect(await controller.invalidatedConnectionNumbers() == [1])
    }

    @Test("disconnect replaces the dead session with a fresh connection")
    func disconnectReplacesDeadSession() async throws {
        let first = try BackendOnlyHostConnectionFixture.make(number: 1)
        let second = try BackendOnlyHostConnectionFixture.make(number: 2)
        let controller = FakeBackendOnlyHostController(
            outcomes: [.connection(first), .connection(second)]
        )
        var observations = await controller.observations().makeAsyncIterator()
        let model = makeModel(controller: controller, maximumConnectionAttempts: 2)

        model.start()
        #expect(await observations.next() == .connectAttempt(1))
        #expect(await observations.next() == .projectionClaim(1))
        #expect(await observations.next() == .eventSubscription(1))
        await controller.disconnect(connectionNumber: 1)

        #expect(await observations.next() == .invalidated(1))
        #expect(await observations.next() == .connectAttempt(2))
        #expect(await observations.next() == .projectionClaim(2))
        #expect(await observations.next() == .eventSubscription(2))
        await model.awaitCurrentConnectionCycle()

        #expect(model.phase == .ready)
        #expect(await controller.invalidatedConnectionNumbers() == [1])
    }

    @Test("automatic reconnect attempts stop at the configured bound")
    func automaticReconnectAttemptsAreBounded() async {
        let controller = FakeBackendOnlyHostController(
            outcomes: [.failure, .failure, .failure, .failure]
        )
        let model = makeModel(controller: controller, maximumConnectionAttempts: 3)

        model.start()
        await model.awaitCurrentConnectionCycle()

        #expect(model.phase == .unavailable)
        #expect(await controller.connectAttemptCount() == 3)
    }

    private func makeModel(
        controller: FakeBackendOnlyHostController,
        maximumConnectionAttempts: Int
    ) -> BackendOnlyHostModel {
        let suiteName = "BackendOnlyHostReconnectTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return BackendOnlyHostModel(
            controller: controller,
            defaults: defaults,
            logicalPresentationID: UUID(),
            maximumConnectionAttempts: maximumConnectionAttempts
        )
    }
}

private actor FakeBackendOnlyHostController: BackendOnlyHostSessionControlling {
    enum Observation: Equatable, Sendable {
        case connectAttempt(Int)
        case projectionClaim(Int)
        case invalidated(Int)
        case eventSubscription(Int)
    }

    enum ConnectOutcome: Sendable {
        case connection(BackendOnlyHostConnection)
        case failure
    }

    private enum Failure: Error {
        case connection
        case projection
    }

    private var outcomes: [ConnectOutcome]
    private let projectionFailures: Set<Int>
    private var attempts = 0
    private var invalidated: [Int] = []
    private var eventContinuations: [
        Int: AsyncStream<BackendCanonicalSessionEvent>.Continuation
    ] = [:]
    private let observationStream: AsyncStream<Observation>
    private let observationContinuation: AsyncStream<Observation>.Continuation

    init(
        outcomes: [ConnectOutcome],
        projectionFailures: Set<Int> = []
    ) {
        self.outcomes = outcomes
        self.projectionFailures = projectionFailures
        let pair = AsyncStream<Observation>.makeStream(
            bufferingPolicy: .unbounded
        )
        observationStream = pair.stream
        observationContinuation = pair.continuation
    }

    func observations() -> AsyncStream<Observation> {
        observationStream
    }

    func connect() async throws -> BackendOnlyHostConnection {
        attempts += 1
        observationContinuation.yield(.connectAttempt(attempts))
        guard !outcomes.isEmpty else { throw Failure.connection }
        switch outcomes.removeFirst() {
        case .connection(let connection):
            return connection
        case .failure:
            throw Failure.connection
        }
    }

    func claimProjectionState(
        for connection: BackendOnlyHostConnection,
        logicalPresentationID: UUID
    ) async throws -> BackendProjectionState {
        let number = try connectionNumber(connection)
        observationContinuation.yield(.projectionClaim(number))
        guard !projectionFailures.contains(number) else {
            throw Failure.projection
        }
        return BackendProjectionState(
            logicalPresentationID: logicalPresentationID,
            generation: 1,
            claimID: UUID(),
            claimedProcessInstanceID: UUID(),
            workspaces: []
        )
    }

    func events(
        for connection: BackendOnlyHostConnection
    ) async -> AsyncStream<BackendCanonicalSessionEvent> {
        let number = (try? connectionNumber(connection)) ?? 0
        let pair = AsyncStream<BackendCanonicalSessionEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        eventContinuations[number] = pair.continuation
        observationContinuation.yield(.eventSubscription(number))
        return pair.stream
    }

    func currentSnapshot(
        for connection: BackendOnlyHostConnection
    ) async -> TopologySnapshot? {
        connection.initialSnapshot
    }

    func invalidate(_ connection: BackendOnlyHostConnection) async {
        guard let number = try? connectionNumber(connection) else { return }
        invalidated.append(number)
        eventContinuations.removeValue(forKey: number)?.finish()
        observationContinuation.yield(.invalidated(number))
    }

    func disconnect(connectionNumber: Int) {
        eventContinuations[connectionNumber]?.yield(
            .disconnected(.topologyStreamFailed("test disconnect"))
        )
    }

    func invalidatedConnectionNumbers() -> [Int] {
        invalidated
    }

    func connectAttemptCount() -> Int {
        attempts
    }

    private func connectionNumber(
        _ connection: BackendOnlyHostConnection
    ) throws -> Int {
        guard let number = Int(connection.readiness.session.split(separator: "-").last ?? "")
        else { throw Failure.connection }
        return number
    }
}

private enum BackendOnlyHostConnectionFixture {
    static func make(number: Int) throws -> BackendOnlyHostConnection {
        let authority = BackendAuthority(
            daemonInstanceID: DaemonInstanceID(rawValue: UUID()),
            sessionID: SessionID(rawValue: UUID())
        )
        let peerIdentity = BackendPeerIdentity(
            processID: UInt32(10_000 + number),
            userID: 501,
            auditToken: BackendAuditToken(
                word0: UInt32(number),
                word1: 0,
                word2: 0,
                word3: 0,
                word4: 0,
                word5: 0,
                word6: 0,
                word7: 0
            )
        )
        let readiness = BackendServiceReadiness(
            authority: authority,
            session: "test-\(number)",
            processID: peerIdentity.processID,
            userID: peerIdentity.userID,
            peerIdentity: peerIdentity,
            peerTrust: BackendPeerTrustEvidence(
                signingIdentifier: "com.cmux.test.backend",
                teamIdentifier: nil,
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                processIDVersion: Int32(number)
            ),
            topologyRevision: 1,
            compatibility: .readWrite(BackendReadWriteCompatibility(
                clientProtocolRange: 9 ... 9,
                serverProtocolRange: 9 ... 9,
                negotiatedProtocol: 9,
                requiredCapabilities: []
            ))
        )
        guard let registration = BackendClientRegistrationIdentity(
            clientUUID: UUID(),
            processInstanceUUID: UUID()
        ) else {
            throw BackendOnlyHostConnectionFixtureError.invalidRegistrationIdentity
        }
        let session = BackendCanonicalSession(
            transport: BackendOnlyHostInertTransport(),
            expectation: BackendCanonicalSessionExpectation(session: readiness.session),
            registrationIdentity: registration
        )
        let snapshot = TopologySnapshot(
            authority: authority,
            revision: 1,
            topology: try CanonicalTopology(workspaces: [])
        )
        return BackendOnlyHostConnection(
            session: session,
            readiness: readiness,
            initialSnapshot: snapshot
        )
    }
}

private enum BackendOnlyHostConnectionFixtureError: Error {
    case invalidRegistrationIdentity
}

private actor BackendOnlyHostInertTransport: BackendPeerIdentityTransport {
    private enum Failure: Error {
        case unavailable
    }

    func connect() async throws {
        throw Failure.unavailable
    }

    func send(_ message: Data) async throws {
        throw Failure.unavailable
    }

    func receive() async throws -> Data {
        throw Failure.unavailable
    }

    func peerIdentity() async throws -> BackendPeerIdentity {
        throw Failure.unavailable
    }

    func close() async {}
}
