import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohServerSessionTests {
    @Test
    func acceptedControlPreservesPayloadAndUnlocksIndependentLanes() async throws {
        let events = TestIrohEventRecorder()
        let fixture = try ServerFixture(decision: .accepted, eventRecorder: events)
        let terminalID = try CmxIrohResourceID("terminal-1")
        let terminalHeader = try fixture.headerCodec.encode(
            CmxIrohStreamHeader(lane: .terminal(resourceID: terminalID, cursor: nil))
        )
        let terminalReceive = TestIrohReceiveStream(
            buffer: terminalHeader + Data("terminal-payload".utf8)
        )
        let terminalSend = TestIrohSendStream()
        let artifactID = try CmxIrohResourceID("artifact:admitted-preview")
        let artifactHeader = try fixture.headerCodec.encode(
            CmxIrohStreamHeader(lane: .artifact(resourceID: artifactID, offset: 4))
        )
        let artifactReceive = TestIrohReceiveStream(
            buffer: artifactHeader + Data("artifact-payload".utf8)
        )
        let connection = TestIrohConnection(
            remoteIdentity: fixture.peerID,
            bidirectionalStreams: [
                fixture.controlStream,
                CmxIrohBidirectionalStream(
                    receiveStream: terminalReceive,
                    sendStream: terminalSend
                ),
                CmxIrohBidirectionalStream(
                    receiveStream: artifactReceive,
                    sendStream: TestIrohSendStream()
                ),
            ],
            eventRecorder: events
        )
        let session = try CmxIrohServerSession(
            connection: connection,
            authorizer: fixture.authorizer,
            protocolConfiguration: .testApplicationLanes
        )

        let admittedPeer = try await session.admit()
        #expect(await connection.observedIncomingStreamLimits() == ["1:0", "17:0"])
        #expect(await connection.observedNatTraversalAuthorizationAttemptCount() == 1)
        #expect(await connection.observedNatTraversalActivationCount() == 1)
        #expect(admittedPeer == fixture.admittedPeer)
        #expect(await events.observedEvents() == [
            "connection.limits:1:0",
            "connection.openBidirectionalStream",
            "control.send",
            "connection.authorizeNatTraversal",
            "control.send",
            "connection.limits:17:0",
        ])
        #expect(try await session.receiveControl() == Data("rpc".utf8))
        let inbound = try await session.acceptBidirectionalLane()
        #expect(inbound.lane == .terminal(resourceID: terminalID, cursor: nil))
        #expect(
            try await inbound.stream.receiveStream.receive(maximumByteCount: 64)
                == Data("terminal-payload".utf8)
        )
        let artifact = try await session.acceptBidirectionalLane()
        #expect(artifact.lane == .artifact(resourceID: artifactID, offset: 4))
        #expect(
            try await artifact.stream.receiveStream.receive(maximumByteCount: 64)
                == Data("artifact-payload".utf8)
        )
        let acknowledgements = await fixture.controlSend.observedSentBuffers()
        let acceptedPending = try #require(acknowledgements.first)
        let serverReady = try #require(acknowledgements.dropFirst().first)
        #expect(acknowledgements.count == 2)
        #expect(try CmxIrohAdmissionAckCodec().decodePrefix(acceptedPending) == .accepted)
        #expect(serverReady == admissionFrame(status: 3))
        try await session.sendControl(Data("control-after-artifact".utf8))
        #expect(
            await fixture.controlSend.observedSentBuffers().last
                == Data("control-after-artifact".utf8)
        )
        #expect(await connection.observedCloseCallCount() == 0)
    }

    @Test
    func productionV1DoesNotGrantOrConsumeReservedApplicationLanes() async throws {
        let fixture = try ServerFixture(decision: .accepted)
        let connection = TestIrohConnection(
            remoteIdentity: fixture.peerID,
            bidirectionalStreams: [
                fixture.controlStream,
                CmxIrohBidirectionalStream(
                    receiveStream: TestIrohReceiveStream(buffer: Data()),
                    sendStream: TestIrohSendStream()
                ),
            ]
        )
        let session = try CmxIrohServerSession(
            connection: connection,
            authorizer: fixture.authorizer
        )

        _ = try await session.admit()

        await #expect(throws: CmxIrohServerSessionError.applicationLanesUnavailable) {
            _ = try await session.acceptBidirectionalLane()
        }
        await #expect(throws: CmxIrohServerSessionError.applicationLanesUnavailable) {
            _ = try await session.openSendLane(
                .artifact(
                    resourceID: CmxIrohResourceID("artifact:reserved"),
                    offset: 0
                ),
                priority: 10
            )
        }
        #expect(await connection.observedIncomingStreamLimits() == ["1:0"])
        #expect(await connection.observedBidirectionalStreamOpenCount() == 1)
    }

    @Test
    func relayOnlyAdmissionCompletesBarrierWithoutAuthorizingNatTraversal() async throws {
        let events = TestIrohEventRecorder()
        let fixture = try ServerFixture(decision: .accepted, eventRecorder: events)
        let connection = TestIrohConnection(
            remoteIdentity: fixture.peerID,
            bidirectionalStreams: [fixture.controlStream],
            eventRecorder: events
        )
        let session = try CmxIrohServerSession(
            connection: connection,
            authorizer: fixture.authorizer,
            protocolConfiguration: .testRelayOnlyApplicationLanes
        )

        _ = try await session.admit()

        #expect(await connection.observedNatTraversalAuthorizationAttemptCount() == 0)
        #expect(await connection.observedNatTraversalActivationCount() == 0)
        #expect(await connection.observedIncomingStreamLimits() == ["1:0", "17:0"])
        #expect(await events.observedEvents() == [
            "connection.limits:1:0",
            "connection.openBidirectionalStream",
            "control.send",
            "control.send",
            "connection.limits:17:0",
        ])
        let acknowledgements = await fixture.controlSend.observedSentBuffers()
        #expect(
            try CmxIrohAdmissionAckCodec().decodeFramePrefix(
                try #require(acknowledgements.first)
            ) == .acceptedRelayOnly
        )
        #expect(
            try CmxIrohAdmissionAckCodec().decodeFramePrefix(
                try #require(acknowledgements.dropFirst().first)
            ) == .serverReady
        )
    }

    @Test
    func denialSendsFixedAckThenClosesTheConnection() async throws {
        let fixture = try ServerFixture(decision: .denied(code: 7))
        let connection = TestIrohConnection(
            remoteIdentity: fixture.peerID,
            bidirectionalStreams: [fixture.controlStream]
        )
        let session = try CmxIrohServerSession(
            connection: connection,
            authorizer: fixture.authorizer
        )

        await #expect(throws: CmxIrohServerSessionError.admissionDenied(code: 7)) {
            try await session.admit()
        }
        let ack = try #require(await fixture.controlSend.observedSentBuffers().first)
        #expect(try CmxIrohAdmissionAckCodec().decodePrefix(ack) == .denied(code: 7))
        #expect(await connection.observedNatTraversalAuthorizationAttemptCount() == 0)
        #expect(await connection.observedCloseCallCount() == 1)
    }

    @Test
    func missingClientReadyFailsClosedWithoutAuthorizingNatTraversal() async throws {
        let fixture = try ServerFixture(
            decision: .accepted,
            clientReadyFrame: nil,
            applicationBytes: Data()
        )
        let connection = TestIrohConnection(
            remoteIdentity: fixture.peerID,
            bidirectionalStreams: [fixture.controlStream]
        )
        let session = try CmxIrohServerSession(
            connection: connection,
            authorizer: fixture.authorizer
        )

        await #expect(throws: CmxIrohServerSessionError.unexpectedEndOfStream) {
            try await session.admit()
        }

        #expect(await fixture.controlSend.observedSentBuffers().count == 1)
        #expect(await connection.observedNatTraversalAuthorizationAttemptCount() == 0)
        #expect(await connection.observedCloseCallCount() == 1)
    }

    @Test
    func cancellationWhileWaitingForClientReadyNeverAuthorizesNatTraversal() async throws {
        let fixture = try ServerFixture(decision: .accepted)
        let credential = try CmxIrohAdmissionCredential.pairGrant("aa.bb.cc")
        let header = try fixture.headerCodec.encode(
            CmxIrohStreamHeader(lane: .control, credential: credential)
        )
        let receive = TestBlockingIrohReceiveStream(buffer: header)
        let controlSend = TestIrohSendStream()
        let connection = TestIrohConnection(
            remoteIdentity: fixture.peerID,
            bidirectionalStreams: [
                CmxIrohBidirectionalStream(
                    receiveStream: receive,
                    sendStream: controlSend
                ),
            ]
        )
        let session = try CmxIrohServerSession(
            connection: connection,
            authorizer: fixture.authorizer
        )
        var blocked = await receive.blockedEvents().makeAsyncIterator()
        let admission = Task { try await session.admit() }
        _ = await blocked.next()

        await #expect(throws: CmxIrohServerSessionError.alreadyAdmitted) {
            try await session.admit()
        }
        await #expect(throws: CmxIrohServerSessionError.notAdmitted) {
            _ = try await session.acceptBidirectionalLane()
        }
        #expect(await connection.observedBidirectionalStreamOpenCount() == 1)

        admission.cancel()

        await #expect(throws: CancellationError.self) {
            try await admission.value
        }
        #expect(await controlSend.observedSentBuffers().count == 1)
        #expect(await connection.observedNatTraversalAuthorizationAttemptCount() == 0)
        #expect(await connection.observedCloseCallCount() == 1)
    }

    @Test
    func roleInvalidClientReadyFailsClosedWithoutAuthorizingNatTraversal() async throws {
        let fixture = try ServerFixture(
            decision: .accepted,
            clientReadyFrame: admissionFrame(status: 3)
        )
        let connection = TestIrohConnection(
            remoteIdentity: fixture.peerID,
            bidirectionalStreams: [fixture.controlStream]
        )
        let session = try CmxIrohServerSession(
            connection: connection,
            authorizer: fixture.authorizer
        )

        await #expect(throws: CmxIrohServerSessionError.invalidAdmissionFrame) {
            try await session.admit()
        }

        #expect(await fixture.controlSend.observedSentBuffers().count == 1)
        #expect(await connection.observedNatTraversalAuthorizationAttemptCount() == 0)
        #expect(await connection.observedCloseCallCount() == 1)
    }

    @Test
    func serverNatTraversalAuthorizationFailureSendsNoFinalReadyAndCloses() async throws {
        let fixture = try ServerFixture(decision: .accepted)
        let connection = TestIrohConnection(
            remoteIdentity: fixture.peerID,
            bidirectionalStreams: [fixture.controlStream],
            natTraversalAuthorizationError: .natTraversalAuthorizationFailed
        )
        let session = try CmxIrohServerSession(
            connection: connection,
            authorizer: fixture.authorizer
        )

        await #expect(throws: TestIrohTransportError.natTraversalAuthorizationFailed) {
            try await session.admit()
        }

        #expect(await fixture.controlSend.observedSentBuffers().count == 1)
        #expect(await connection.observedNatTraversalAuthorizationAttemptCount() == 1)
        #expect(await connection.observedNatTraversalActivationCount() == 0)
        #expect(await connection.observedCloseCallCount() == 1)
    }

    @Test
    func acceptedContextMustMatchTheTLSAuthenticatedPeer() async throws {
        let fixture = try ServerFixture(decision: .accepted)
        let substitutedPeer = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "b", count: 64)
        )
        let connection = TestIrohConnection(
            remoteIdentity: substitutedPeer,
            bidirectionalStreams: [fixture.controlStream]
        )
        let session = try CmxIrohServerSession(
            connection: connection,
            authorizer: fixture.authorizer
        )

        await #expect(throws: CmxIrohServerSessionError.admissionDenied(code: 1)) {
            try await session.admit()
        }
        let ack = try #require(await fixture.controlSend.observedSentBuffers().first)
        #expect(try CmxIrohAdmissionAckCodec().decodePrefix(ack) == .denied(code: 1))
        #expect(await connection.observedCloseCallCount() == 1)
    }

    @Test
    func admittedControlUsesTheSharedByteTransportContract() async throws {
        let fixture = try ServerFixture(decision: .accepted)
        let connection = TestIrohConnection(
            remoteIdentity: fixture.peerID,
            bidirectionalStreams: [fixture.controlStream]
        )
        let session = try CmxIrohServerSession(
            connection: connection,
            authorizer: fixture.authorizer
        )
        _ = try await session.admit()
        let transport = CmxIrohServerByteTransport(session: session)

        try await transport.connect()
        #expect(try await transport.receive() == Data("rpc".utf8))
        try await transport.send(Data("response".utf8))
        await transport.close()

        let buffers = await fixture.controlSend.observedSentBuffers()
        #expect(buffers.last == Data("response".utf8))
        #expect(await connection.observedCloseCallCount() == 1)
    }

    @Test
    func nonControlFirstStreamFailsBeforeAuthorization() async throws {
        let fixture = try ServerFixture(decision: .accepted)
        let terminalHeader = try fixture.headerCodec.encode(
            CmxIrohStreamHeader(
                lane: .terminal(resourceID: CmxIrohResourceID("terminal-1"), cursor: nil)
            )
        )
        let receive = TestIrohReceiveStream(buffer: terminalHeader)
        let send = TestIrohSendStream()
        let connection = TestIrohConnection(
            remoteIdentity: fixture.peerID,
            bidirectionalStreams: [
                CmxIrohBidirectionalStream(receiveStream: receive, sendStream: send),
            ]
        )
        let session = try CmxIrohServerSession(
            connection: connection,
            authorizer: fixture.authorizer
        )

        await #expect(throws: CmxIrohServerSessionError.invalidFirstLane) {
            try await session.admit()
        }
        #expect(await fixture.authorizer.callCount() == 0)
        #expect(await connection.observedCloseCallCount() == 1)
    }

    @Test
    func serverSendLaneWritesHeaderBeforePayloadAndSetsPriority() async throws {
        let fixture = try ServerFixture(decision: .accepted)
        let laneSend = TestIrohSendStream()
        let connection = TestIrohConnection(
            remoteIdentity: fixture.peerID,
            bidirectionalStreams: [
                fixture.controlStream,
                CmxIrohBidirectionalStream(
                    receiveStream: TestIrohReceiveStream(buffer: Data()),
                    sendStream: laneSend
                ),
            ]
        )
        let session = try CmxIrohServerSession(
            connection: connection,
            authorizer: fixture.authorizer
        )
        try await session.admit()

        let lane = CmxIrohLane.serverEvents(cursor: nil)
        let stream = try await session.openSendLane(lane, priority: 42)
        try await stream.send(Data("event".utf8))
        let buffers = await laneSend.observedSentBuffers()
        let header = try fixture.headerCodec.decodePrefix(try #require(buffers.first))
        #expect(header.header.lane == lane)
        #expect(buffers.last == Data("event".utf8))
        #expect(await laneSend.observedPriorities() == [42])
    }

    @Test
    func admittedHostValueKeepsControlAndIndependentLanesReachable() async throws {
        let fixture = try ServerFixture(decision: .accepted)
        let terminalID = try CmxIrohResourceID("terminal-1")
        let terminalReceive = TestIrohReceiveStream(
            buffer: try fixture.headerCodec.encode(
                CmxIrohStreamHeader(
                    lane: .terminal(resourceID: terminalID, cursor: nil)
                )
            ) + Data("terminal".utf8)
        )
        let eventSend = TestIrohSendStream()
        let connection = TestIrohConnection(
            remoteIdentity: fixture.peerID,
            bidirectionalStreams: [
                fixture.controlStream,
                CmxIrohBidirectionalStream(
                    receiveStream: terminalReceive,
                    sendStream: TestIrohSendStream()
                ),
                CmxIrohBidirectionalStream(
                    receiveStream: TestIrohReceiveStream(buffer: Data()),
                    sendStream: eventSend
                ),
            ]
        )
        let server = try CmxIrohServerSession(
            connection: connection,
            authorizer: fixture.authorizer,
            protocolConfiguration: .testApplicationLanes
        )
        let peer = try await server.admit()
        let admitted = CmxIrohAdmittedServerSession(peer: peer, session: server)

        try await admitted.controlTransport.connect()
        #expect(try await admitted.controlTransport.receive() == Data("rpc".utf8))
        let terminal = try await admitted.acceptBidirectionalLane()
        #expect(terminal.lane == .terminal(resourceID: terminalID, cursor: nil))
        #expect(
            try await terminal.stream.receiveStream.receive(maximumByteCount: 64)
                == Data("terminal".utf8)
        )
        let events = try await admitted.openSendLane(
            .serverEvents(cursor: 9),
            priority: 50
        )
        try await events.send(Data("event".utf8))
        #expect(await eventSend.observedPriorities() == [50])
        #expect(await eventSend.observedSentBuffers().count == 2)

        await admitted.close()
        #expect(await connection.observedCloseCallCount() == 1)
    }
}
