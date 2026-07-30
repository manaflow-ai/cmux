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
    func oneControlOwnerIsEnforcedAndReleaseClosesThePeerConnection() async throws {
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
        await #expect(throws: CmxIrohByteTransportError.controlLaneAlreadyOwned) {
            _ = try await peer.acquireControl(for: request, ownerID: secondOwner)
        }
        await peer.releaseControl(ownerID: firstOwner)

        #expect(await firstSession.closeCount() == 1)
        #expect(await peer.snapshot().phase == .disconnected)
        _ = try await peer.acquireControl(for: request, ownerID: secondOwner)
        #expect(await builder.callCount() == 2)
        #expect(await peer.connectionContinuityID() == 12)
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
