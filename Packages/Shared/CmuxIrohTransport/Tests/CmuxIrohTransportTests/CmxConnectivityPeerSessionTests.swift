import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

struct CmxConnectivityPeerSessionTests {
    @Test
    func concurrentCallersShareOneDialAndOneAdmittedSession() async throws {
        let request = try Self.request()
        let routeVariant = try Self.request(routeID: "iroh-v2-refreshed")
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
        let second = Task { try await peer.connectedSession(for: routeVariant) }
        await builder.release()

        _ = try await first.value
        _ = try await second.value

        #expect(await builder.callCount() == 1)
        #expect(await peer.snapshot().phase == .connected)
        #expect(await peer.snapshot().connectionGeneration == 1)
    }

    @Test
    func nextControlOwnerWaitsAndReleasePreservesThePeerConnection() async throws {
        let request = try Self.request()
        let routeVariant = try Self.request(routeID: "iroh-v2-refreshed")
        let peerID = try CmxConnectivityPeerID(request: request)
        let firstSession = TestConnectivitySession(continuityID: 11)
        let builder = SequencedConnectivitySessionBuilder(
            sessions: [firstSession]
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
            try await peer.acquireControl(for: routeVariant, ownerID: secondOwner)
        }
        for _ in 0 ..< 100 {
            await Task.yield()
            #expect(await builder.callCount() == 1)
        }
        await peer.releaseControl(ownerID: firstOwner)

        #expect(await firstSession.closeCount() == 0)
        _ = try await secondAcquire.value
        #expect(await builder.callCount() == 1)
        #expect(await peer.connectionContinuityID() == 11)
        await peer.updateControlPurpose(
            ownerID: secondOwner,
            purpose: .backgroundControl
        )
        #expect(await peer.snapshot().controlPurpose == .backgroundControl)
        await peer.releaseControl(ownerID: firstOwner)
        #expect(await firstSession.closeCount() == 0)
        await peer.releaseControl(ownerID: secondOwner)
        #expect(await firstSession.closeCount() == 0)
    }

    @Test
    func cancelledControlWaiterCannotBlockTheNextOwner() async throws {
        let request = try Self.request()
        let peerID = try CmxConnectivityPeerID(request: request)
        let firstSession = TestConnectivitySession(continuityID: 13)
        let builder = SequencedConnectivitySessionBuilder(
            sessions: [firstSession]
        )
        let peer = CmxConnectivityPeerSession(
            peerID: peerID,
            buildSession: { request in
                try await builder.build(request)
            }
        )
        let firstOwner = UUID()

        _ = try await peer.acquireControl(for: request, ownerID: firstOwner)
        let cancelled = Task {
            try await peer.acquireControl(for: request, ownerID: UUID())
        }
        for _ in 0 ..< 100 { await Task.yield() }
        cancelled.cancel()
        if case .success = await cancelled.result {
            Issue.record("The cancelled control waiter unexpectedly acquired ownership")
        }

        let nextOwner = UUID()
        let next = Task {
            try await peer.acquireControl(for: request, ownerID: nextOwner)
        }
        for _ in 0 ..< 100 {
            await Task.yield()
            #expect(await builder.callCount() == 1)
        }
        await peer.releaseControl(ownerID: firstOwner)
        _ = try await next.value

        #expect(await builder.callCount() == 1)
        #expect(await peer.connectionContinuityID() == 13)
        await peer.releaseControl(ownerID: nextOwner)
    }

    @Test
    func controlFailureHandsOffOnTheSameConnectionWithoutClosingFeatureLanes() async throws {
        let request = try Self.request()
        let peerID = try CmxConnectivityPeerID(request: request)
        let session = TestConnectivitySession(continuityID: 15)
        let builder = SequencedConnectivitySessionBuilder(sessions: [session])
        let peer = CmxConnectivityPeerSession(
            peerID: peerID,
            buildSession: { request in
                try await builder.build(request)
            }
        )
        let failedOwner = UUID()
        let replacementOwner = UUID()

        _ = try await peer.acquireControl(for: request, ownerID: failedOwner)
        await peer.releaseControl(
            ownerID: failedOwner,
            reason: .controlReadFailed,
            failure: .connectionClosed
        )
        _ = try await peer.acquireControl(
            for: request,
            ownerID: replacementOwner
        )

        #expect(await builder.callCount() == 1)
        #expect(await peer.connectionContinuityID() == 15)
        #expect(await session.closeCount() == 0)
        await peer.releaseControl(ownerID: replacementOwner)
    }

    @Test
    func failedControlRepairFallsBackToExactlyOneFreshDial() async throws {
        let request = try Self.request()
        let peerID = try CmxConnectivityPeerID(request: request)
        let failed = TestConnectivitySession(
            continuityID: 16,
            repairError: .unsupported
        )
        let replacement = TestConnectivitySession(continuityID: 17)
        let builder = SequencedConnectivitySessionBuilder(
            sessions: [failed, replacement]
        )
        let peer = CmxConnectivityPeerSession(
            peerID: peerID,
            buildSession: { request in
                try await builder.build(request)
            }
        )
        let failedOwner = UUID()
        let replacementOwner = UUID()
        _ = try await peer.acquireControl(for: request, ownerID: failedOwner)
        await peer.releaseControl(
            ownerID: failedOwner,
            reason: .controlWriteFailed,
            failure: .transportIdleTimedOut
        )

        _ = try await peer.acquireControl(
            for: request,
            ownerID: replacementOwner
        )

        #expect(await failed.repairCallCount() == 1)
        #expect(await failed.closeCount() == 1)
        #expect(await builder.callCount() == 2)
        #expect(await peer.connectionContinuityID() == 17)
        await peer.releaseControl(ownerID: replacementOwner)
    }

    @Test
    func newClientUsesLegacyHeaderAndFullRedialForAnOldMac() async throws {
        let request = try Self.request()
        let peerID = try CmxConnectivityPeerID(request: request)
        let localIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "b", count: 64)
        )
        let credential = try CmxIrohAdmissionCredential.pairGrant("e30.e30.AA")
        let firstSend = TestIrohSendStream()
        let secondSend = TestIrohSendStream()
        let ready = CmxIrohAdmissionAckCodec().encodeFrame(
            .acceptedPendingNatTraversal
        ) + CmxIrohAdmissionAckCodec().encodeFrame(.serverReady)
        let firstConnection = TestIrohConnection(
            remoteIdentity: peerID.identity,
            continuityID: 81,
            bidirectionalStreams: [
                CmxIrohBidirectionalStream(
                    receiveStream: TestIrohReceiveStream(buffer: ready),
                    sendStream: firstSend
                ),
            ]
        )
        let secondConnection = TestIrohConnection(
            remoteIdentity: peerID.identity,
            continuityID: 82,
            bidirectionalStreams: [
                CmxIrohBidirectionalStream(
                    receiveStream: TestIrohReceiveStream(buffer: ready),
                    sendStream: secondSend
                ),
            ]
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: localIdentity,
            dialResults: [
                .connection(firstConnection),
                .connection(secondConnection),
            ]
        )
        let peer = CmxConnectivityPeerSession(
            peerID: peerID,
            processIncarnation: UUID(),
            engineGeneration: 4,
            buildSession: { _, attempt in
                let session = try CmxIrohClientSession(
                    endpoint: endpoint,
                    targetIdentity: peerID.identity,
                    dialPlan: try testIrohDialPlan(),
                    credential: credential,
                    connectionAttempt: attempt,
                    supportsControlRepair: false
                )
                try await session.connect()
                return session
            }
        )
        let firstOwner = UUID()
        let successorOwner = UUID()

        _ = try await peer.acquireControl(for: request, ownerID: firstOwner)
        await peer.releaseControl(
            ownerID: firstOwner,
            reason: .controlReadFailed,
            failure: .connectionClosed
        )
        _ = try await peer.acquireControl(
            for: request,
            ownerID: successorOwner
        )

        let legacyHeader = Self.legacyPairGrantControlHeader("e30.e30.AA")
        #expect(await firstSend.observedSentBuffers().first == legacyHeader)
        #expect(await secondSend.observedSentBuffers().first == legacyHeader)
        #expect(await firstConnection.observedCloseCallCount() == 1)
        #expect(await endpoint.observedDialedAddresses().count == 2)
        #expect(await peer.connectionContinuityID() == 82)
        await peer.releaseControl(ownerID: successorOwner)
        await peer.invalidate()
    }

    @Test
    func cleanControlEOFRepairsOnTheSameConnectionForTheNextTransport() async throws {
        let request = try Self.request()
        let session = TestConnectivitySession(continuityID: 18)
        let builder = SequencedConnectivitySessionBuilder(sessions: [session])
        let peer = CmxConnectivityPeerSession(
            peerID: try CmxConnectivityPeerID(request: request),
            buildSession: { request in
                try await builder.build(request)
            }
        )
        let engine = TestPeerControlEngine(peer: peer)
        let first = CmxConnectivityByteTransport(
            request: request,
            engine: engine
        )
        let successor = CmxConnectivityByteTransport(
            request: request,
            engine: engine
        )

        try await first.connect()
        #expect(try await first.receive() == nil)
        try await successor.connect()

        #expect(await session.repairCallCount() == 1)
        #expect(await session.closeCount() == 0)
        #expect(await builder.callCount() == 1)
        #expect(await successor.transportContinuityID() == 18)
        await successor.close()
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
    func cancelledDialDrainsWithoutDelayingTheReplacement() async throws {
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
        try await Self.waitUntil { await builder.callCount() == 2 }
        await builder.release(call: 1)

        _ = try await second.value
        #expect(await peer.connectionContinuityID() == 42)
        #expect(await retired.closeCount() == 0)

        await builder.release(call: 0)
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
        deviceID: String = "123e4567-e89b-42d3-a456-426614174999",
        routeID: String = "iroh-v2"
    ) throws -> CmxByteTransportRequest {
        let identity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "a", count: 64)
        )
        return CmxByteTransportRequest(
            route: try CmxAttachRoute(
                id: routeID,
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

    private static func legacyPairGrantControlHeader(_ token: String) -> Data {
        let tokenBytes = Data(token.utf8)
        var payload = Data()
        var tokenLength = UInt16(tokenBytes.count).bigEndian
        withUnsafeBytes(of: &tokenLength) { payload.append(contentsOf: $0) }
        payload.append(tokenBytes)

        var frame = Data("CMUXIRH1".utf8)
        frame.append(contentsOf: [1, 1, 0, 1])
        var payloadLength = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &payloadLength) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }
}

private actor TestPeerControlEngine: CmxConnectivityControlOwning {
    private let peer: CmxConnectivityPeerSession

    init(peer: CmxConnectivityPeerSession) {
        self.peer = peer
    }

    func acquireControl(
        for request: CmxByteTransportRequest,
        ownerID: UUID
    ) async throws -> any CmxConnectivitySession {
        try await peer.acquireControl(for: request, ownerID: ownerID)
    }

    func releaseControl(
        for request: CmxByteTransportRequest,
        ownerID: UUID,
        reason: DiagnosticSessionLifecycleKind,
        failure: DiagnosticFailureKind
    ) async {
        _ = request
        await peer.releaseControl(
            ownerID: ownerID,
            reason: reason,
            failure: failure
        )
    }

    func updateControlPurpose(
        for request: CmxByteTransportRequest,
        ownerID: UUID,
        purpose: CmxTransportSessionPurpose
    ) async {
        _ = request
        await peer.updateControlPurpose(ownerID: ownerID, purpose: purpose)
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
    private let repairError: TestConnectivitySessionError?
    private var closed = false
    private var closes = 0
    private var repairCalls = 0
    private var closeFailure = DiagnosticFailureKind.connectionClosed
    private var closureWaiters: [CheckedContinuation<Void, Never>] = []
    private var received: [Data] = []

    init(
        continuityID: UInt64,
        repairError: TestConnectivitySessionError? = nil
    ) {
        self.continuityID = continuityID
        self.repairError = repairError
    }

    func repairControl() throws {
        repairCalls += 1
        if let repairError { throw repairError }
    }

    func repairCallCount() -> Int { repairCalls }

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
