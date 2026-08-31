import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

/// Bounded-dial behavior (cmux#9724, cmux#8531): a dial attempt whose
/// admission barrier never answers must fail at the configured dial bound and
/// leave the session redialable, instead of holding the reconnect owner for
/// an unbounded time. A half-ready Mac accepts the QUIC connection but never
/// serves the admission frames; that exact shape produced the unbounded
/// 16.2-second dial in the cmux#9724 trace.
@Suite
struct CmxIrohClientSessionDialBoundTests {
    let localIdentity: CmxIrohPeerIdentity
    let remoteIdentity: CmxIrohPeerIdentity
    let credential: CmxIrohAdmissionCredential

    init() throws {
        localIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "ab", count: 32)
        )
        remoteIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "cd", count: 32)
        )
        credential = try .pairGrant("e30.e30.AA")
    }

    @Test("an admission barrier that never answers fails at the dial bound")
    func admissionBarrierThatNeverAnswersFailsAtTheDialBound() async throws {
        let control = CmxIrohBidirectionalStream(
            receiveStream: TestHangingIrohReceiveStream(),
            sendStream: TestIrohSendStream()
        )
        let connection = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            bidirectionalStreams: [control]
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: localIdentity,
            dialResults: [.connection(connection)]
        )
        let session = try CmxIrohClientSession(
            endpoint: endpoint,
            targetIdentity: remoteIdentity,
            dialPlan: try testIrohDialPlan(publicPaths: [try publicRelayHint()]),
            credential: credential,
            dialPhaseTimeout: .milliseconds(40)
        )

        let failure = await boundedConnectFailure(session, within: .seconds(2))
        #expect(failure as? CmxIrohClientSessionError == .dialTimedOut)
        #expect(await connection.observedCloseCallCount() >= 1)
        await session.close()
    }

    @Test("a timed-out admission is superseded by the next connect attempt")
    func timedOutAdmissionIsSupersededByTheNextConnectAttempt() async throws {
        let hangingControl = CmxIrohBidirectionalStream(
            receiveStream: TestHangingIrohReceiveStream(),
            sendStream: TestIrohSendStream()
        )
        let hangingConnection = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            bidirectionalStreams: [hangingControl]
        )
        let goodConnection = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            bidirectionalStreams: [answeringControlStream()]
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: localIdentity,
            dialResults: [
                .connection(hangingConnection),
                .connection(goodConnection),
            ]
        )
        let session = try CmxIrohClientSession(
            endpoint: endpoint,
            targetIdentity: remoteIdentity,
            dialPlan: try testIrohDialPlan(publicPaths: [try publicRelayHint()]),
            credential: credential,
            dialPhaseTimeout: .milliseconds(40)
        )

        let failure = await boundedConnectFailure(session, within: .seconds(2))
        #expect(failure as? CmxIrohClientSessionError == .dialTimedOut)

        // The timed-out attempt must have been retired cleanly: the very next
        // attempt on the same session dials again and admits.
        try await session.connect()

        #expect(await endpoint.observedDialedAddresses().count == 2)
        #expect(await hangingConnection.observedCloseCallCount() >= 1)
        await session.close()
    }

    // MARK: - Support

    /// Runs `connect()` under a test watchdog so the red state (an unbounded
    /// admission hang) fails this test quickly instead of hanging the suite.
    private func boundedConnectFailure(
        _ session: CmxIrohClientSession,
        within limit: Duration
    ) async -> (any Error)? {
        let connectTask = Task { try await session.connect() }
        let watchdog = Task {
            try? await ContinuousClock().sleep(for: limit)
            connectTask.cancel()
        }
        defer { watchdog.cancel() }
        do {
            _ = try await connectTask.value
            return nil
        } catch {
            return error
        }
    }

    private func answeringControlStream() -> CmxIrohBidirectionalStream {
        let codec = CmxIrohAdmissionAckCodec()
        let accepted = codec.encodeFrame(.acceptedPendingNatTraversal)
        let serverReady = codec.encodeFrame(.serverReady)
        return CmxIrohBidirectionalStream(
            receiveStream: TestIrohReceiveStream(buffer: accepted + serverReady),
            sendStream: TestIrohSendStream()
        )
    }

    private func publicRelayHint() throws -> CmxIrohPathHint {
        try CmxIrohPathHint(
            kind: .relayURL,
            value: "https://use1-1.relay.lawrence.cmux.iroh.link/",
            source: .native,
            privacyScope: .publicInternet
        )
    }
}

/// A control stream that never yields admission bytes. The hang is
/// cancellable, mirroring the production stream contract the phase bound
/// relies on (`TestIrohDialResult.hang` models the same shape for dials).
actor TestHangingIrohReceiveStream: CmxIrohReceiveStream {
    private var stoppedCodes: [UInt64] = []

    func receive(maximumByteCount _: Int) async throws -> Data? {
        try await Task.sleep(for: .seconds(3_600))
        return nil
    }

    func stop(errorCode: UInt64) {
        stoppedCodes.append(errorCode)
    }

    func observedStoppedCodes() -> [UInt64] {
        stoppedCodes
    }
}
