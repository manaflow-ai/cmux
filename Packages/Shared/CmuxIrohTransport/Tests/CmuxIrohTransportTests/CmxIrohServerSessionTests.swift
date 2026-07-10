import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohServerSessionTests {
    @Test
    func acceptedControlPreservesPayloadAndUnlocksIndependentLanes() async throws {
        let fixture = try ServerFixture(decision: .accepted)
        let terminalID = try CmxIrohResourceID("terminal-1")
        let terminalHeader = try fixture.headerCodec.encode(
            CmxIrohStreamHeader(lane: .terminal(resourceID: terminalID, cursor: nil))
        )
        let terminalReceive = TestIrohReceiveStream(
            buffer: terminalHeader + Data("terminal-payload".utf8)
        )
        let terminalSend = TestIrohSendStream()
        let connection = TestIrohConnection(
            remoteIdentity: fixture.peerID,
            bidirectionalStreams: [
                fixture.controlStream,
                CmxIrohBidirectionalStream(
                    receiveStream: terminalReceive,
                    sendStream: terminalSend
                ),
            ]
        )
        let session = try CmxIrohServerSession(
            connection: connection,
            authorizer: fixture.authorizer
        )

        let admittedPeer = try await session.admit()
        #expect(admittedPeer == fixture.admittedPeer)
        #expect(try await session.receiveControl() == Data("rpc".utf8))
        let inbound = try await session.acceptBidirectionalLane()
        #expect(inbound.lane == .terminal(resourceID: terminalID, cursor: nil))
        #expect(
            try await inbound.stream.receiveStream.receive(maximumByteCount: 64)
                == Data("terminal-payload".utf8)
        )
        let ack = try #require(await fixture.controlSend.observedSentBuffers().first)
        #expect(try CmxIrohAdmissionAckCodec().decodePrefix(ack) == .accepted)
        #expect(await connection.observedCloseCallCount() == 0)
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
            authorizer: fixture.authorizer
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

private struct ServerFixture {
    let peerID: CmxIrohPeerIdentity
    let admittedPeer: CmxIrohAdmittedPeer
    let authorizer: FixedAdmissionAuthorizer
    let headerCodec = try! CmxIrohStreamHeaderCodec()
    let controlSend = TestIrohSendStream()
    let controlStream: CmxIrohBidirectionalStream

    init(decision: CmxIrohAdmissionDecision) throws {
        let peerID = try CmxIrohPeerIdentity(endpointID: String(repeating: "a", count: 64))
        let admittedPeer = CmxIrohAdmittedPeer(
            bindingID: "123e4567-e89b-42d3-a456-426614174001",
            deviceID: "123e4567-e89b-42d3-a456-426614174002",
            endpointID: peerID,
            identityGeneration: 7,
            platform: .ios
        )
        self.peerID = peerID
        self.admittedPeer = admittedPeer
        let authorization: CmxIrohAdmissionAuthorization = switch decision {
        case .accepted:
            .accepted(admittedPeer)
        case let .denied(code):
            .denied(code: code)
        }
        authorizer = FixedAdmissionAuthorizer(authorization: authorization)
        let credential = try CmxIrohAdmissionCredential.pairGrant("aa.bb.cc")
        let header = try headerCodec.encode(
            CmxIrohStreamHeader(lane: .control, credential: credential)
        )
        controlStream = CmxIrohBidirectionalStream(
            receiveStream: TestIrohReceiveStream(buffer: header + Data("rpc".utf8)),
            sendStream: controlSend
        )
    }
}

private actor FixedAdmissionAuthorizer: CmxIrohAdmissionAuthorizing {
    private let authorization: CmxIrohAdmissionAuthorization
    private var observedCalls = 0

    init(authorization: CmxIrohAdmissionAuthorization) {
        self.authorization = authorization
    }

    func authorize(
        credential _: CmxIrohAdmissionCredential,
        authenticatedPeerID _: CmxIrohPeerIdentity
    ) -> CmxIrohAdmissionAuthorization {
        observedCalls += 1
        return authorization
    }

    func callCount() -> Int { observedCalls }
}
