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
        let stoppedEvents = await stalledReceive.stoppedEvents()
        let accept = Task { try await session.acceptBidirectionalLane() }
        _ = await blocked.next()
        await clock.waitUntilSleeping()

        await clock.fire()
        let stoppedCode = await firstStopCode(in: stoppedEvents, timeout: .seconds(1))

        await #expect(throws: CmxIrohServerSessionError.applicationLaneRejected) {
            try await accept.value
        }
        #expect(stoppedCode == 1)
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
        let stoppedEvents = await stalledReceive.stoppedEvents()
        let rejected = Task { try await session.acceptBidirectionalLane() }
        _ = await blocked.next()
        await clock.waitUntilSleeping()

        await clock.fire()
        let stoppedCode = await firstStopCode(in: stoppedEvents, timeout: .seconds(1))
        await #expect(throws: CmxIrohServerSessionError.applicationLaneRejected) {
            try await rejected.value
        }
        #expect(stoppedCode == 1)

        let accepted = try await session.acceptBidirectionalLane()
        #expect(accepted.lane == .terminal(resourceID: terminalID, cursor: 42))
        #expect(
            try await accepted.stream.receiveStream.receive(maximumByteCount: 64)
                == Data("payload".utf8)
        )
        #expect(await connection.observedCloseCallCount() == 0)
    }
}

private func firstStopCode(
    in events: AsyncStream<UInt64>,
    timeout: Duration
) async -> UInt64? {
    await withTaskGroup(of: UInt64?.self) { group in
        group.addTask {
            var iterator = events.makeAsyncIterator()
            return await iterator.next()
        }
        group.addTask {
            do {
                try await ContinuousClock().sleep(for: timeout)
            } catch {
                return nil
            }
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
