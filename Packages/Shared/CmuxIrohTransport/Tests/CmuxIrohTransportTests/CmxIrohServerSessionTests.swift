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

        try await session.admit()
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
}

private struct ServerFixture {
    let peerID: CmxIrohPeerIdentity
    let authorizer: FixedAdmissionAuthorizer
    let headerCodec = try! CmxIrohStreamHeaderCodec()
    let controlSend = TestIrohSendStream()
    let controlStream: CmxIrohBidirectionalStream

    init(decision: CmxIrohAdmissionDecision) throws {
        peerID = try CmxIrohPeerIdentity(endpointID: String(repeating: "a", count: 64))
        authorizer = FixedAdmissionAuthorizer(decision: decision)
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
    private let decision: CmxIrohAdmissionDecision
    private var observedCalls = 0

    init(decision: CmxIrohAdmissionDecision) {
        self.decision = decision
    }

    func authorize(
        credential _: CmxIrohAdmissionCredential,
        authenticatedPeerID _: CmxIrohPeerIdentity
    ) -> CmxIrohAdmissionDecision {
        observedCalls += 1
        return decision
    }

    func callCount() -> Int { observedCalls }
}
