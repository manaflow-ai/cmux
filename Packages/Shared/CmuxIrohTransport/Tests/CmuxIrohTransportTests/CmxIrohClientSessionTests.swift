import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohClientSessionTests {
    private let localIdentity: CmxIrohPeerIdentity
    private let remoteIdentity: CmxIrohPeerIdentity
    private let credential: CmxIrohAdmissionCredential

    init() throws {
        localIdentity = try CmxIrohPeerIdentity(endpointID: String(repeating: "ab", count: 32))
        remoteIdentity = try CmxIrohPeerIdentity(endpointID: String(repeating: "cd", count: 32))
        credential = try .pairGrant("e30.e30.AA")
    }

    @Test
    func publicDialAdmitsControlAndPreservesFollowingRPCBytes() async throws {
        let control = controlStream(
            decision: .accepted,
            trailingBytes: Data("rpc".utf8)
        )
        let connection = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            bidirectionalStreams: [control.stream]
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: localIdentity,
            dialResults: [.connection(connection)]
        )
        let publicHint = try publicRelayHint()
        let session = try CmxIrohClientSession(
            endpoint: endpoint,
            targetIdentity: remoteIdentity,
            dialPlan: CmxIrohDialPlan(publicPaths: [publicHint], privateFallbackPaths: []),
            credential: credential
        )

        try await session.connect()

        let dialed = await endpoint.observedDialedAddresses()
        #expect(dialed == [CmxIrohEndpointAddress(identity: remoteIdentity, pathHints: [publicHint])])
        let sent = await control.send.observedSentBuffers()
        #expect(sent.count == 1)
        let decodedHeader = try CmxIrohStreamHeaderCodec().decodePrefix(sent[0]).header
        #expect(decodedHeader == (try CmxIrohStreamHeader(lane: .control, credential: credential)))
        #expect(try await session.receiveControl() == Data("rpc".utf8))
    }

    @Test
    func privateHintsAreAttemptedOnlyAfterPublicFailure() async throws {
        let control = controlStream(decision: .accepted)
        let connection = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            bidirectionalStreams: [control.stream]
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: localIdentity,
            dialResults: [
                .failure(.unsupported),
                .connection(connection),
            ]
        )
        let publicHint = try publicRelayHint()
        let privateHint = try tailscaleHint()
        let session = try CmxIrohClientSession(
            endpoint: endpoint,
            targetIdentity: remoteIdentity,
            dialPlan: CmxIrohDialPlan(
                publicPaths: [publicHint],
                privateFallbackPaths: [privateHint]
            ),
            credential: credential
        )

        try await session.connect()

        let dialed = await endpoint.observedDialedAddresses()
        #expect(dialed.map(\.pathHints) == [[publicHint], [privateHint]])
    }

    @Test
    func mismatchedTLSIdentityClosesBeforeOpeningAControlStream() async throws {
        let attackerIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "ef", count: 32)
        )
        let connection = TestIrohConnection(
            remoteIdentity: attackerIdentity,
            bidirectionalStreams: []
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: localIdentity,
            dialResults: [.connection(connection)]
        )
        let session = try CmxIrohClientSession(
            endpoint: endpoint,
            targetIdentity: remoteIdentity,
            dialPlan: CmxIrohDialPlan(publicPaths: [], privateFallbackPaths: []),
            credential: credential
        )

        await #expect(throws: CmxIrohClientSessionError.remoteIdentityMismatch) {
            try await session.connect()
        }
        #expect(await connection.observedCloseCallCount() == 1)
    }

    @Test
    func deniedAdmissionClosesTheWholeConnection() async throws {
        let control = controlStream(decision: .denied(code: 7))
        let connection = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            bidirectionalStreams: [control.stream]
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: localIdentity,
            dialResults: [.connection(connection)]
        )
        let session = try CmxIrohClientSession(
            endpoint: endpoint,
            targetIdentity: remoteIdentity,
            dialPlan: CmxIrohDialPlan(publicPaths: [], privateFallbackPaths: []),
            credential: credential
        )

        await #expect(throws: CmxIrohClientSessionError.admissionDenied(code: 7)) {
            try await session.connect()
        }
        #expect(await connection.observedCloseCallCount() == 1)
    }

    @Test
    func terminalLaneGetsIndependentHeaderAndPriority() async throws {
        let control = controlStream(decision: .accepted)
        let terminalReceive = TestIrohReceiveStream(buffer: Data())
        let terminalSend = TestIrohSendStream()
        let terminalStream = CmxIrohBidirectionalStream(
            receiveStream: terminalReceive,
            sendStream: terminalSend
        )
        let connection = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            bidirectionalStreams: [control.stream, terminalStream]
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: localIdentity,
            dialResults: [.connection(connection)]
        )
        let session = try CmxIrohClientSession(
            endpoint: endpoint,
            targetIdentity: remoteIdentity,
            dialPlan: CmxIrohDialPlan(publicPaths: [], privateFallbackPaths: []),
            credential: credential
        )
        try await session.connect()
        let lane = CmxIrohLane.terminal(
            resourceID: try CmxIrohResourceID("terminal:42"),
            cursor: 9
        )

        _ = try await session.openBidirectionalLane(lane, priority: 50)

        #expect(await terminalSend.observedPriorities() == [50])
        let sent = await terminalSend.observedSentBuffers()
        #expect(sent.count == 1)
        #expect(try CmxIrohStreamHeaderCodec().decodePrefix(sent[0]).header.lane == lane)
    }

    @Test
    func inboundArtifactHeaderIsRemovedWithoutDroppingPayload() async throws {
        let control = controlStream(decision: .accepted)
        let artifactLane = CmxIrohLane.artifact(
            resourceID: try CmxIrohResourceID("artifact:preview"),
            offset: 128
        )
        let artifactHeader = try CmxIrohStreamHeaderCodec().encode(
            CmxIrohStreamHeader(lane: artifactLane)
        )
        let artifactPayload = Data("preview".utf8)
        let artifactReceive = TestIrohReceiveStream(
            buffer: artifactHeader + artifactPayload
        )
        let connection = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            bidirectionalStreams: [control.stream],
            receiveStreams: [artifactReceive]
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: localIdentity,
            dialResults: [.connection(connection)]
        )
        let session = try CmxIrohClientSession(
            endpoint: endpoint,
            targetIdentity: remoteIdentity,
            dialPlan: CmxIrohDialPlan(publicPaths: [], privateFallbackPaths: []),
            credential: credential
        )
        try await session.connect()

        let inbound = try await session.acceptInboundStream()

        #expect(inbound.lane == artifactLane)
        #expect(try await inbound.receiveStream.receive(maximumByteCount: 64) == artifactPayload)
    }

    @Test
    func cancellingConnectCancelsTheUnderlyingIrohDial() async throws {
        let endpoint = TestHangingDialEndpoint(localIdentity: localIdentity)
        let session = try CmxIrohClientSession(
            endpoint: endpoint,
            targetIdentity: remoteIdentity,
            dialPlan: CmxIrohDialPlan(publicPaths: [], privateFallbackPaths: []),
            credential: credential
        )
        var started = await endpoint.startedEvents().makeAsyncIterator()
        var cancelled = await endpoint.cancelledEvents().makeAsyncIterator()
        let connection = Task { try await session.connect() }
        _ = await started.next()

        connection.cancel()

        _ = await cancelled.next()
        await #expect(throws: CancellationError.self) {
            try await connection.value
        }
    }

    private func controlStream(
        decision: CmxIrohAdmissionDecision,
        trailingBytes: Data = Data()
    ) -> (stream: CmxIrohBidirectionalStream, send: TestIrohSendStream) {
        let receive = TestIrohReceiveStream(
            buffer: CmxIrohAdmissionAckCodec().encode(decision) + trailingBytes
        )
        let send = TestIrohSendStream()
        return (
            CmxIrohBidirectionalStream(receiveStream: receive, sendStream: send),
            send
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

    private func tailscaleHint() throws -> CmxIrohPathHint {
        let observedAt = Date(timeIntervalSince1970: 1_000)
        return try CmxIrohPathHint(
            kind: .directAddress,
            value: "100.64.0.8:4242",
            source: .tailscale,
            privacyScope: .privateNetwork,
            observedAt: observedAt,
            expiresAt: observedAt.addingTimeInterval(30 * 60),
            networkProfile: CmxIrohNetworkProfileKey(
                source: .tailscale,
                profileID: "tailnet-a"
            )
        )
    }
}
