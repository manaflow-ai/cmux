import Foundation
import Testing
@testable import CmuxIrohTransport

extension CmxIrohServerSessionTests {
    @Test
    func applicationLaneHeaderTimeoutStopsCancellationIgnoringRead() async throws {
        let fixture = try ServerFixture(decision: .accepted)
        let stalledReceive = TestBlockingIrohReceiveStream(
            buffer: Data(),
            cancellationUnblocksReceive: false
        )
        let stalledSend = TestIrohSendStream()
        let clock = ServerSessionManualClock()
        let connection = TestIrohConnection(
            remoteIdentity: fixture.peerID,
            bidirectionalStreams: [
                fixture.controlStream,
                CmxIrohBidirectionalStream(
                    receiveStream: stalledReceive,
                    sendStream: stalledSend
                ),
            ]
        )
        let session = try CmxIrohServerSession(
            connection: connection,
            authorizer: fixture.authorizer,
            protocolConfiguration: .testApplicationLanes,
            streamHeaderClock: clock,
            streamHeaderTimeout: 1
        )
        _ = try await session.admit()
        var blocked = await stalledReceive.blockedEvents().makeAsyncIterator()
        let accept = Task { try await session.acceptBidirectionalLane() }
        _ = await blocked.next()
        await clock.waitUntilSleeping()

        await clock.fire()
        for _ in 0 ..< 100 where await stalledReceive.observedStoppedCodes().isEmpty {
            await Task.yield()
        }
        let stoppedBeforeFallback = await stalledReceive.observedStoppedCodes()
        if stoppedBeforeFallback.isEmpty {
            await stalledReceive.releaseWithoutStopping()
        }

        await #expect(throws: CmxIrohServerSessionError.applicationLaneRejected) {
            try await accept.value
        }
        #expect(!stoppedBeforeFallback.isEmpty)
        #expect(await stalledSend.observedResetCodes() == [1])
    }

    @Test
    func rejectedApplicationLaneDoesNotConsumeTheNextValidLane() async throws {
        let fixture = try ServerFixture(decision: .accepted)
        let stalledReceive = TestBlockingIrohReceiveStream(
            buffer: Data(),
            cancellationUnblocksReceive: false
        )
        let stalledSend = TestIrohSendStream()
        let terminalID = try CmxIrohResourceID("terminal:recovered")
        let validHeader = try fixture.headerCodec.encode(
            CmxIrohStreamHeader(
                lane: .terminal(resourceID: terminalID, cursor: 42)
            )
        )
        let clock = ServerSessionManualClock()
        let connection = TestIrohConnection(
            remoteIdentity: fixture.peerID,
            bidirectionalStreams: [
                fixture.controlStream,
                CmxIrohBidirectionalStream(
                    receiveStream: stalledReceive,
                    sendStream: stalledSend
                ),
                CmxIrohBidirectionalStream(
                    receiveStream: TestIrohReceiveStream(
                        buffer: validHeader + Data("payload".utf8)
                    ),
                    sendStream: TestIrohSendStream()
                ),
            ]
        )
        let session = try CmxIrohServerSession(
            connection: connection,
            authorizer: fixture.authorizer,
            protocolConfiguration: .testApplicationLanes,
            streamHeaderClock: clock,
            streamHeaderTimeout: 1
        )
        _ = try await session.admit()
        var blocked = await stalledReceive.blockedEvents().makeAsyncIterator()
        let rejected = Task { try await session.acceptBidirectionalLane() }
        _ = await blocked.next()
        await clock.waitUntilSleeping()

        await clock.fire()
        for _ in 0 ..< 100 where await stalledReceive.observedStoppedCodes().isEmpty {
            await Task.yield()
        }
        if await stalledReceive.observedStoppedCodes().isEmpty {
            await stalledReceive.releaseWithoutStopping()
        }
        await #expect(throws: CmxIrohServerSessionError.applicationLaneRejected) {
            try await rejected.value
        }

        let accepted = try await session.acceptBidirectionalLane()
        #expect(accepted.lane == .terminal(resourceID: terminalID, cursor: 42))
        #expect(
            try await accepted.stream.receiveStream.receive(maximumByteCount: 64)
                == Data("payload".utf8)
        )
        #expect(await connection.observedCloseCallCount() == 0)
    }
}
