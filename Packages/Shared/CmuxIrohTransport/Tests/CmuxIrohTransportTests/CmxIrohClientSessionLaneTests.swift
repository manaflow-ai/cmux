import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

extension CmxIrohClientSessionTests {
    @Test
    func terminalLaneGetsIndependentHeaderAndPriority() async throws {
        let control = controlStream(decision: .accepted)
        let terminalSend = TestIrohSendStream()
        let terminalStream = CmxIrohBidirectionalStream(
            receiveStream: TestIrohReceiveStream(buffer: Data()),
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
            dialPlan: try testIrohDialPlan(),
            credential: credential,
            protocolConfiguration: .testApplicationLanes
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
    func productionV1RejectsReservedApplicationLaneBeforeOpeningAStream() async throws {
        let control = controlStream(decision: .accepted)
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
            dialPlan: try testIrohDialPlan(),
            credential: credential
        )
        try await session.connect()

        await #expect(throws: CmxIrohClientSessionError.applicationLanesUnavailable) {
            _ = try await session.openBidirectionalLane(
                .artifact(
                    resourceID: CmxIrohResourceID("artifact:reserved"),
                    offset: 0
                ),
                priority: 10
            )
        }

        #expect(await connection.observedBidirectionalStreamOpenCount() == 1)
    }

    @Test
    func serverEventReceiverRemovesItsLaneHeaderWithoutDroppingPayload() async throws {
        let control = controlStream(decision: .accepted)
        let eventHeader = try CmxIrohStreamHeaderCodec().encode(
            CmxIrohStreamHeader(lane: .serverEvents(cursor: nil))
        )
        let eventPayload = Data("event-frame".utf8)
        let eventReceive = TestIrohReceiveStream(buffer: eventHeader + eventPayload)
        let connection = TestIrohConnection(
            remoteIdentity: remoteIdentity,
            bidirectionalStreams: [control.stream],
            receiveStreams: [eventReceive]
        )
        let endpoint = TestDialingIrohEndpoint(
            localIdentity: localIdentity,
            dialResults: [.connection(connection)]
        )
        let session = try CmxIrohClientSession(
            endpoint: endpoint,
            targetIdentity: remoteIdentity,
            dialPlan: try testIrohDialPlan(),
            credential: credential
        )
        try await session.connect()

        let stream = try await session.serverEventByteStream()
        var bytes = stream.makeAsyncIterator()

        #expect(try await bytes.next() == eventPayload)
        #expect(await connection.observedIncomingStreamLimits().first == "0:0")
        #expect(await connection.observedIncomingStreamLimits().contains("0:1"))
        await session.close()
        #expect(await connection.observedIncomingStreamLimits().last == "0:0")
    }

    @Test
    func cancellingConnectCancelsTheUnderlyingIrohDial() async throws {
        let endpoint = TestHangingDialEndpoint(localIdentity: localIdentity)
        let session = try CmxIrohClientSession(
            endpoint: endpoint,
            targetIdentity: remoteIdentity,
            dialPlan: try testIrohDialPlan(),
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
}
