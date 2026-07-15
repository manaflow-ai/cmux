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

        await #expect(throws: CmxIrohServerSessionError.streamHeaderTimedOut) {
            try await accept.value
        }
        #expect(!stoppedBeforeFallback.isEmpty)
        #expect(await stalledSend.observedResetCodes() == [1])
    }
}
