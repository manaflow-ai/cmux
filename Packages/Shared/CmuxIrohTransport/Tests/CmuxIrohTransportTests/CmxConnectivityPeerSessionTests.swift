import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

struct CmxConnectivityPeerSessionTests {
    @Test
    func concurrentCallersShareOneDialAndOneAdmittedSession() async throws {
        let request = try Self.request()
        let peerID = try CmxConnectivityPeerID(request: request)
        let admitted = TestConnectivitySession(continuityID: 7)
        let builder = GatedConnectivitySessionBuilder(session: admitted)
        let peer = CmxConnectivityPeerSession(
            peerID: peerID,
            buildSession: { request in
                try await builder.build(request)
            }
        )

        let first = Task { try await peer.connectedSession(for: request) }
        try await Self.waitUntil { await builder.callCount() == 1 }
        let second = Task { try await peer.connectedSession(for: request) }
        await builder.release()

        _ = try await first.value
        _ = try await second.value

        #expect(await builder.callCount() == 1)
        #expect(await peer.snapshot().phase == .connected)
        #expect(await peer.snapshot().connectionGeneration == 1)
    }

    @Test
    func nextControlOwnerWaitsAndReleaseClosesThePeerConnection() async throws {
        let request = try Self.request()
        let peerID = try CmxConnectivityPeerID(request: request)
        let firstSession = TestConnectivitySession(continuityID: 11)
        let secondSession = TestConnectivitySession(continuityID: 12)
        let builder = SequencedConnectivitySessionBuilder(
            sessions: [firstSession, secondSession]
        )
        let peer = CmxConnectivityPeerSession(
            peerID: peerID,
            buildSession: { request in
                try await builder.build(request)
            }
        )
        let firstOwner = UUID()
        let secondOwner = UUID()

        _ = try await peer.acquireControl(for: request, ownerID: firstOwner)
        let secondAcquire = Task {
            try await peer.acquireControl(for: request, ownerID: secondOwner)
        }
        for _ in 0 ..< 100 {
            await Task.yield()
            #expect(await builder.callCount() == 1)
        }
        await peer.releaseControl(ownerID: firstOwner)

        #expect(await firstSession.closeCount() == 1)
        _ = try await secondAcquire.value
        #expect(await builder.callCount() == 2)
        #expect(await peer.connectionContinuityID() == 12)
        await peer.releaseControl(ownerID: secondOwner)
    }

    @Test
    func remoteClosureClearsOwnershipAndTheNextOperationRedials() async throws {
        let request = try Self.request()
        let peerID = try CmxConnectivityPeerID(request: request)
        let firstSession = TestConnectivitySession(continuityID: 21)
        let secondSession = TestConnectivitySession(continuityID: 22)
        let builder = SequencedConnectivitySessionBuilder(
            sessions: [firstSession, secondSession]
        )
        let peer = CmxConnectivityPeerSession(
            peerID: peerID,
            buildSession: { request in
                try await builder.build(request)
            }
        )
        let firstOwner = UUID()

        _ = try await peer.acquireControl(for: request, ownerID: firstOwner)
        await firstSession.finishRemotely(failure: .transportIdleTimedOut)
        try await Self.waitUntil {
            await peer.snapshot().phase == .failed
        }

        let failed = await peer.snapshot()
        #expect(failed.failure == .transportIdleTimedOut)
        #expect(!failed.controlLaneOwned)
        _ = try await peer.acquireControl(for: request, ownerID: UUID())
        #expect(await builder.callCount() == 2)
        #expect(await peer.connectionContinuityID() == 22)
    }

    @Test
    func deadOnArrivalSessionIsClosedAndRedialedOnce() async throws {
        let request = try Self.request()
        let peerID = try CmxConnectivityPeerID(request: request)
        let dead = TestConnectivitySession(continuityID: 31)
        await dead.finishRemotely(failure: .connectionClosed)
        let live = TestConnectivitySession(continuityID: 32)
        let builder = SequencedConnectivitySessionBuilder(
            sessions: [dead, live]
        )
        let peer = CmxConnectivityPeerSession(
            peerID: peerID,
            buildSession: { request in
                try await builder.build(request)
            }
        )

        _ = try await peer.connectedSession(for: request)

        #expect(await builder.callCount() == 2)
        #expect(await dead.closeCount() == 1)
        #expect(await peer.connectionContinuityID() == 32)
        await peer.invalidate()
    }

    @Test
    func cancelledDialDrainsBeforeTheReplacementStarts() async throws {
        let request = try Self.request()
        let peerID = try CmxConnectivityPeerID(request: request)
        let retired = TestConnectivitySession(continuityID: 41)
        let live = TestConnectivitySession(continuityID: 42)
        let builder = OrderedGatedConnectivitySessionBuilder(
            sessions: [retired, live]
        )
        let peer = CmxConnectivityPeerSession(
            peerID: peerID,
            buildSession: { request in
                try await builder.build(request)
            }
        )

        let first = Task { try await peer.connectedSession(for: request) }
        try await Self.waitUntil { await builder.callCount() == 1 }
        await peer.invalidate()
        let second = Task { try await peer.connectedSession(for: request) }
        for _ in 0 ..< 100 {
            await Task.yield()
            #expect(await builder.callCount() == 1)
        }
        await builder.release(call: 0)
        try await Self.waitUntil { await builder.callCount() == 2 }
        await builder.release(call: 1)

        _ = try await second.value
        if case .success = await first.result {
            Issue.record("The retired dial unexpectedly succeeded")
        }
        #expect(await retired.closeCount() == 1)
        #expect(await peer.connectionContinuityID() == 42)
        await peer.invalidate()
    }

    @Test
    func wedgedRetiredDialCannotBlockPastTheSettleBound() async throws {
        let request = try Self.request()
        let peerID = try CmxConnectivityPeerID(request: request)
        let retired = TestConnectivitySession(continuityID: 51)
        let live = TestConnectivitySession(continuityID: 52)
        let builder = OrderedGatedConnectivitySessionBuilder(
            sessions: [retired, live]
        )
        let peer = CmxConnectivityPeerSession(
            peerID: peerID,
            buildSession: { request in
                try await builder.build(request)
            },
            clock: ImmediateHostActivationClock()
        )

        let first = Task { try await peer.connectedSession(for: request) }
        try await Self.waitUntil { await builder.callCount() == 1 }
        await peer.invalidate()
        let second = Task { try await peer.connectedSession(for: request) }
        try await Self.waitUntil { await builder.callCount() == 2 }
        await builder.release(call: 1)
        _ = try await second.value
        await builder.release(call: 0)
        if case .success = await first.result {
            Issue.record("The retired dial unexpectedly succeeded")
        }
        try await Self.waitUntil { await retired.closeCount() == 1 }
        #expect(await peer.connectionContinuityID() == 52)
        await peer.invalidate()
    }

    @Test
    func sessionOwnerRejectsSubstitutedPeerIntentBeforeDialing() async throws {
        let request = try Self.request()
        let peerID = try CmxConnectivityPeerID(request: request)
        let builder = SequencedConnectivitySessionBuilder(
            sessions: [TestConnectivitySession(continuityID: 1)]
        )
        let peer = CmxConnectivityPeerSession(
            peerID: peerID,
            buildSession: { request in
                try await builder.build(request)
            }
        )
        let substituted = try Self.request(
            deviceID: "223e4567-e89b-42d3-a456-426614174999"
        )

        await #expect(throws: CmxConnectivityEngineError.peerIntentMismatch) {
            _ = try await peer.connectedSession(for: substituted)
        }
        #expect(await builder.callCount() == 0)
    }

    private static func request(
        deviceID: String = "123e4567-e89b-42d3-a456-426614174999"
    ) throws -> CmxByteTransportRequest {
        let identity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "a", count: 64)
        )
        return CmxByteTransportRequest(
            route: try CmxAttachRoute(
                id: "iroh-v2",
                kind: .iroh,
                endpoint: .peer(identity: identity, pathHints: [])
            ),
            expectedPeerDeviceID: deviceID,
            authorizationMode: .transportAdmission
        )
    }

    private static func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0 ..< 1_000 {
            if await condition() { return }
            await Task.yield()
        }
        struct TimedOut: Error {}
        throw TimedOut()
    }
}

private actor GatedConnectivitySessionBuilder {
    private let session: any CmxConnectivitySession
    private var calls = 0
    private var gate: CheckedContinuation<Void, Never>?

    init(session: any CmxConnectivitySession) {
        self.session = session
    }

    func build(
        _ request: CmxByteTransportRequest
    ) async throws -> any CmxConnectivitySession {
        _ = request
        calls += 1
        await withCheckedContinuation { continuation in
            gate = continuation
        }
        return session
    }

    func release() {
        gate?.resume()
        gate = nil
    }

    func callCount() -> Int { calls }
}

private actor SequencedConnectivitySessionBuilder {
    private var sessions: [any CmxConnectivitySession]
    private var calls = 0

    init(sessions: [any CmxConnectivitySession]) {
        self.sessions = sessions
    }

    func build(
        _ request: CmxByteTransportRequest
    ) throws -> any CmxConnectivitySession {
        _ = request
        calls += 1
        return sessions.removeFirst()
    }

    func callCount() -> Int { calls }
}

private actor OrderedGatedConnectivitySessionBuilder {
    private let sessions: [any CmxConnectivitySession]
    private var calls = 0
    private var gates: [Int: CheckedContinuation<Void, Never>] = [:]

    init(sessions: [any CmxConnectivitySession]) {
        self.sessions = sessions
    }

    func build(
        _ request: CmxByteTransportRequest
    ) async throws -> any CmxConnectivitySession {
        _ = request
        let call = calls
        calls += 1
        await withCheckedContinuation { continuation in
            gates[call] = continuation
        }
        return sessions[call]
    }

    func release(call: Int) {
        gates.removeValue(forKey: call)?.resume()
    }

    func callCount() -> Int { calls }
}

private actor TestConnectivitySession: CmxConnectivitySession {
    private let continuityID: UInt64
    private var closed = false
    private var closes = 0
    private var closeFailure = DiagnosticFailureKind.connectionClosed
    private var closureWaiters: [CheckedContinuation<Void, Never>] = []
    private var received: [Data] = []

    init(continuityID: UInt64) {
        self.continuityID = continuityID
    }

    func receiveControl(maximumByteCount: Int) -> Data? {
        guard maximumByteCount > 0, !received.isEmpty else { return nil }
        return received.removeFirst()
    }

    func sendControl(_ data: Data) {
        received.append(data)
    }

    func openBidirectionalLane(
        _ lane: CmxIrohLane,
        priority: Int32
    ) throws -> CmxIrohBidirectionalStream {
        _ = lane
        _ = priority
        throw TestConnectivitySessionError.unsupported
    }

    func serverEventByteStream() throws -> CmxIndependentEventByteStream {
        throw TestConnectivitySessionError.unsupported
    }

    func waitUntilClosed() async {
        if closed { return }
        await withCheckedContinuation { continuation in
            closureWaiters.append(continuation)
        }
    }

    func closeAttribution() -> CmxIrohConnectionCloseAttribution {
        CmxIrohConnectionCloseAttribution(
            initiator: .remote,
            applicationErrorCode: nil,
            failureKind: closeFailure
        )
    }

    func isClosed() -> Bool { closed }

    func connectionContinuityID() -> UInt64? {
        closed ? nil : continuityID
    }

    func observedSelectedPath() -> CmxIrohObservedConnectionPath {
        closed ? .unavailable : .direct
    }

    func observedSelectedPathChanges() -> AsyncStream<CmxIrohObservedConnectionPath> {
        AsyncStream { continuation in
            continuation.yield(closed ? .unavailable : .direct)
            continuation.finish()
        }
    }

    func observedPathEvents() -> AsyncStream<CmxIrohConnectionPathEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func close() {
        closes += 1
        finish(failure: .cancelled)
    }

    func finishRemotely(failure: DiagnosticFailureKind) {
        finish(failure: failure)
    }

    func closeCount() -> Int { closes }

    private func finish(failure: DiagnosticFailureKind) {
        guard !closed else { return }
        closed = true
        closeFailure = failure
        let waiters = closureWaiters
        closureWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private enum TestConnectivitySessionError: Error {
    case unsupported
}
