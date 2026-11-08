import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohClientServerEventReceiverTests {
    @Test
    func oneAcceptOwnerRejectsOtherLanesAndDeliversServerEventBytes() async throws {
        let identity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "ef", count: 32)
        )
        let codec = try CmxIrohStreamHeaderCodec()
        let artifactReceive = TestIrohReceiveStream(
            buffer: try codec.encode(
                CmxIrohStreamHeader(
                    lane: .artifact(
                        resourceID: CmxIrohResourceID("artifact:unexpected"),
                        offset: 0
                    )
                )
            )
        )
        let payload = Data("framed-event".utf8)
        let eventReceive = TestIrohReceiveStream(
            buffer: try codec.encode(
                CmxIrohStreamHeader(lane: .serverEvents(cursor: nil))
            ) + payload
        )
        let connection = TestIrohConnection(
            remoteIdentity: identity,
            bidirectionalStreams: [],
            receiveStreams: [artifactReceive, eventReceive]
        )
        let receiver = try CmxIrohClientServerEventReceiver(connection: connection)

        let byteStream = try await receiver.byteStream()
        var bytes = byteStream.makeAsyncIterator()

        #expect(try await bytes.next() == payload)
        #expect(await artifactReceive.observedStoppedCodes() == [1])
        #expect(await connection.observedReceiveStreamAcceptCount() == 2)
        await receiver.close()
        #expect(await connection.observedIncomingStreamLimits().first == "0:1")
        #expect(await connection.observedIncomingStreamLimits().last == "0:0")
    }

    @Test
    func aSecondConsumerCannotCreateACompetingAcceptLoop() async throws {
        let identity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "12", count: 32)
        )
        let blocking = TestBlockingIrohReceiveStream(buffer: Data())
        let connection = TestIrohConnection(
            remoteIdentity: identity,
            bidirectionalStreams: [],
            receiveStreams: [blocking]
        )
        let receiver = try CmxIrohClientServerEventReceiver(connection: connection)

        let firstStream = try await receiver.byteStream()
        var blockedEvents = await blocking.blockedEvents().makeAsyncIterator()
        _ = await blockedEvents.next()

        await #expect(
            throws: CmxIrohClientServerEventReceiverError.consumerAlreadyActive
        ) {
            _ = try await receiver.byteStream()
        }
        #expect(await connection.observedReceiveStreamAcceptCount() == 1)
        _ = firstStream

        await receiver.close()
    }
}
