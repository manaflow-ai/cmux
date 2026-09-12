import Foundation
import Testing
@testable import CmuxNextTransport

@Suite("Admission deadline ownership")
struct ConnectAttemptDeadlineTests {
    @Test("timeout closes an admission returned by the cancelled loser", .timeLimit(.minutes(1)))
    func timeoutClosesLateAdmission() async throws {
        let rig = try ReconnectOwnerTests.Rig()
        let admitted = try await rig.connectOnce()
        guard case .admitted(let connection, _) = admitted else {
            Issue.record("The real admission fixture was denied")
            return
        }
        let started = AsyncStream.makeStream(of: Void.self)
        let cancelled = AsyncStream.makeStream(of: Void.self)
        await #expect(throws: TransportError.dialTimeout) {
            _ = try await ConnectAttemptDeadline().run(connect: {
                started.continuation.finish()
                // Models a native result delivered while cancellation unwinds.
                // No wall-clock sleep controls which race leg wins.
                for await _ in cancelled.stream {}
                return admitted
            }, timeout: {
                for await _ in started.stream {}
            })
        }
        #expect(await connection.isClosed)
        _ = await rig.host.reapClosedSessions()
        #expect(await rig.host.sessionCount == 0)
        await connection.closeAll()
    }

    @Test("parent cancellation closes a late admission", .timeLimit(.minutes(1)))
    func cancellationClosesLateAdmission() async throws {
        let rig = try ReconnectOwnerTests.Rig()
        let admitted = try await rig.connectOnce()
        guard case .admitted(let connection, _) = admitted else {
            Issue.record("The real admission fixture was denied")
            return
        }
        let started = AsyncStream.makeStream(of: Void.self)
        let cancelled = AsyncStream.makeStream(of: Void.self)
        let deadline = AsyncStream.makeStream(of: Void.self)
        let attempt = Task {
            try await ConnectAttemptDeadline().run(connect: {
                started.continuation.finish()
                for await _ in cancelled.stream {}
                return admitted
            }, timeout: {
                for await _ in deadline.stream {}
                try Task.checkCancellation()
            })
        }
        for await _ in started.stream {}
        attempt.cancel()
        await #expect(throws: CancellationError.self) { _ = try await attempt.value }
        #expect(await connection.isClosed)
        _ = await rig.host.reapClosedSessions()
        #expect(await rig.host.sessionCount == 0)
        await connection.closeAll()
    }

    @Test("winning admission remains usable after the timer is cancelled", .timeLimit(.minutes(1)))
    func winningAdmissionStaysOpen() async throws {
        let rig = try ReconnectOwnerTests.Rig()
        let deadline = AsyncStream.makeStream(of: Void.self)
        let result = try await ConnectAttemptDeadline().run(connect: {
            try await rig.connectOnce()
        }, timeout: {
            for await _ in deadline.stream {}
            try Task.checkCancellation()
        })
        guard case .admitted(let connection, let sessionID) = result else {
            Issue.record("A winning admission was lost")
            return
        }
        #expect(sessionID == "s1")
        #expect(await connection.isClosed == false)
        let lane = await connection.lane(TransportHost.echoLaneName)
        let frame = Frame.dataChunk(seq: 1, data: Data([1, 2, 3]))
        try await lane.send(frame)
        #expect(await lane.receive() == frame)
        await connection.closeAll()
    }
}
