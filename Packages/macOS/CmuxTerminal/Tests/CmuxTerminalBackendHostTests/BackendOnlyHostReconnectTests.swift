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

    @Test("rapid projection selections coalesce behind one in-flight write")
    func rapidProjectionSelectionsCoalesceToNewestPendingWrite() async throws {
        let workspaces = BackendOnlyHostConnectionFixture.makeWorkspaces(count: 32)
        let connection = try BackendOnlyHostConnectionFixture.make(
            number: 1,
            workspaces: workspaces
        )
        let controller = FakeBackendOnlyHostController(
            outcomes: [.connection(connection)],
            blockFirstProjectionUpdate: true
        )
        var updates = await controller.projectionUpdates().makeAsyncIterator()
        let model = makeModel(controller: controller, maximumConnectionAttempts: 1)

        model.start()

        let first = try #require(await updates.next())
        #expect(first.workspaceID == workspaces[0].uuid)
        #expect(first.expectedGeneration == 1)

        for workspace in workspaces.dropFirst() {
            model.selectWorkspace(workspace.uuid.rawValue)
        }

        let blockedMetrics = await controller.projectionUpdateMetrics()
        #expect(blockedMetrics.attempts.count == 1)
        #expect(blockedMetrics.inFlight == 1)
        #expect(blockedMetrics.maximumInFlight == 1)

        await controller.releaseFirstProjectionUpdate()
        let coalesced = try #require(await updates.next())
        #expect(coalesced.workspaceID == workspaces.last?.uuid)
        #expect(coalesced.expectedGeneration == 2)
        await model.awaitProjectionPersistence()

        let finalMetrics = await controller.projectionUpdateMetrics()
        #expect(finalMetrics.attempts == [first, coalesced])
        #expect(finalMetrics.inFlight == 0)
        #expect(finalMetrics.maximumInFlight == 1)
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

    struct ProjectionUpdateAttempt: Equatable, Sendable {
        let workspaceID: WorkspaceID
        let expectedGeneration: UInt64
    }

    struct ProjectionUpdateMetrics: Equatable, Sendable {
        let attempts: [ProjectionUpdateAttempt]
        let inFlight: Int
        let maximumInFlight: Int
    }

    private enum Failure: Error {
        case connection
        case projection
    }

    private var outcomes: [ConnectOutcome]
    private let projectionFailures: Set<Int>
    private let blockFirstProjectionUpdate: Bool
    private var attempts = 0
    private var invalidated: [Int] = []
    private var eventContinuations: [
        Int: AsyncStream<BackendCanonicalSessionEvent>.Continuation
    ] = [:]
    private let observationStream: AsyncStream<Observation>
    private let observationContinuation: AsyncStream<Observation>.Continuation
    private let projectionUpdateStream: AsyncStream<ProjectionUpdateAttempt>
    private let projectionUpdateContinuation:
        AsyncStream<ProjectionUpdateAttempt>.Continuation
    private var projectionUpdateAttempts: [ProjectionUpdateAttempt] = []
    private var projectionUpdatesInFlight = 0
    private var maximumProjectionUpdatesInFlight = 0
    private var firstProjectionUpdateContinuation: CheckedContinuation<Void, Never>?

    init(
        outcomes: [ConnectOutcome],
        projectionFailures: Set<Int> = [],
        blockFirstProjectionUpdate: Bool = false
    ) {
        self.outcomes = outcomes
        self.projectionFailures = projectionFailures
        self.blockFirstProjectionUpdate = blockFirstProjectionUpdate
        let pair = AsyncStream<Observation>.makeStream(
            bufferingPolicy: .unbounded
        )
        observationStream = pair.stream
        observationContinuation = pair.continuation
        let projectionPair = AsyncStream<ProjectionUpdateAttempt>.makeStream(
            bufferingPolicy: .unbounded
        )
        projectionUpdateStream = projectionPair.stream
        projectionUpdateContinuation = projectionPair.continuation
    }

    func observations() -> AsyncStream<Observation> {
        observationStream
    }

    func projectionUpdates() -> AsyncStream<ProjectionUpdateAttempt> {
        projectionUpdateStream
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

    func updateProjectionState(
        for connection: BackendOnlyHostConnection,
        logicalPresentationID: UUID,
        claimID: UUID,
        expectedGeneration: UInt64,
        workspaces: [BackendProjectionWorkspaceState]
    ) async throws -> BackendProjectionState {
        guard let workspaceID = workspaces.first?.workspaceID else {
            throw Failure.projection
        }
        let attempt = ProjectionUpdateAttempt(
            workspaceID: workspaceID,
            expectedGeneration: expectedGeneration
        )
        projectionUpdateAttempts.append(attempt)
        projectionUpdatesInFlight += 1
        maximumProjectionUpdatesInFlight = max(
            maximumProjectionUpdatesInFlight,
            projectionUpdatesInFlight
        )
        projectionUpdateContinuation.yield(attempt)
        defer { projectionUpdatesInFlight -= 1 }

        if blockFirstProjectionUpdate, projectionUpdateAttempts.count == 1 {
            await withCheckedContinuation { continuation in
                firstProjectionUpdateContinuation = continuation
            }
        }

        return BackendProjectionState(
            logicalPresentationID: logicalPresentationID,
            generation: expectedGeneration + 1,
            claimID: claimID,
            claimedProcessInstanceID: UUID(),
            workspaces: workspaces
        )
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

    func projectionUpdateMetrics() -> ProjectionUpdateMetrics {
        ProjectionUpdateMetrics(
            attempts: projectionUpdateAttempts,
            inFlight: projectionUpdatesInFlight,
            maximumInFlight: maximumProjectionUpdatesInFlight
        )
    }

    func releaseFirstProjectionUpdate() {
        firstProjectionUpdateContinuation?.resume()
        firstProjectionUpdateContinuation = nil
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
    static func make(
        number: Int,
        workspaces: [CanonicalWorkspace] = []
    ) throws -> BackendOnlyHostConnection {
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
            topology: try CanonicalTopology(workspaces: workspaces)
        )
        return BackendOnlyHostConnection(
            session: session,
            readiness: readiness,
            initialSnapshot: snapshot
        )
    }

    static func makeWorkspaces(count: Int) -> [CanonicalWorkspace] {
        (0 ..< count).map { offset in
            let base = UInt64(offset * 10)
            let workspaceID = WorkspaceID(rawValue: UUID())
            let screenID = ScreenID(rawValue: UUID())
            let paneID = PaneID(rawValue: UUID())
            let surfaceID = SurfaceID(rawValue: UUID())
            return CanonicalWorkspace(
                id: base + 1,
                uuid: workspaceID,
                name: "workspace-\(offset)",
                screens: [
                    CanonicalScreen(
                        id: base + 2,
                        uuid: screenID,
                        name: nil,
                        layout: .leaf(pane: base + 3, paneUUID: paneID),
                        panes: [
                            CanonicalPane(
                                id: base + 3,
                                uuid: paneID,
                                name: nil,
                                tabs: [
                                    CanonicalSurface(
                                        id: base + 4,
                                        uuid: surfaceID,
                                        kind: "browser",
                                        name: nil
                                    ),
                                ]
                            ),
                        ]
                    ),
                ]
            )
        }
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
