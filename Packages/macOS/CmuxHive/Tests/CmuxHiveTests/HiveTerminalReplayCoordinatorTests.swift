import Foundation
import Testing
@testable import CmuxHive

@MainActor
struct HiveTerminalReplayCoordinatorTests {
    private enum Failure: Error { case replay }

    @Test(.timeLimit(.minutes(1)))
    func refreshWaitersShareOneRequest() async throws {
        let coordinator = HiveTerminalReplayCoordinator()
        let gate = HiveSessionTeardownGate()
        var requests = 0
        let first = Task {
            try await coordinator.run(afterCurrent: false) {
                requests += 1
                await gate.wait()
            }
        }
        var started = gate.started.stream.makeAsyncIterator()
        _ = try #require(await started.next())
        let joined = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let second = Task {
            joined.continuation.yield(())
            try await coordinator.run(afterCurrent: false) { requests += 1 }
        }
        var joining = joined.stream.makeAsyncIterator()
        _ = try #require(await joining.next())
        #expect(requests == 1)
        await gate.release()
        try await first.value
        try await second.value
        #expect(requests == 1)
        #expect(!coordinator.isRunning)
    }

    @Test(.timeLimit(.minutes(1)))
    func aNewSubscriptionRequestsAFreshSnapshotEvenIfTheOldRequestFails() async throws {
        let coordinator = HiveTerminalReplayCoordinator()
        let gate = HiveSessionTeardownGate()
        var requestedFreshSnapshot = false
        let first = Task {
            try await coordinator.run(afterCurrent: false) {
                await gate.wait()
                throw Failure.replay
            }
        }
        var started = gate.started.stream.makeAsyncIterator()
        _ = try #require(await started.next())
        let waiting = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let second = Task {
            waiting.continuation.yield(())
            try await coordinator.run(afterCurrent: true) { requestedFreshSnapshot = true }
        }
        var listener = waiting.stream.makeAsyncIterator()
        _ = try #require(await listener.next())
        #expect(!requestedFreshSnapshot)
        await gate.release()
        await #expect(throws: Failure.self) { try await first.value }
        try await second.value
        #expect(requestedFreshSnapshot)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledRequestCannotClearItsSuccessorsOwnership() async throws {
        let coordinator = HiveTerminalReplayCoordinator()
        let oldGate = HiveSessionTeardownGate()
        let newGate = HiveSessionTeardownGate()
        let first = Task {
            try await coordinator.run(afterCurrent: false) { await oldGate.wait() }
        }
        var oldStarted = oldGate.started.stream.makeAsyncIterator()
        _ = try #require(await oldStarted.next())
        coordinator.cancel()
        let second = Task {
            try await coordinator.run(afterCurrent: false) { await newGate.wait() }
        }
        var newStarted = newGate.started.stream.makeAsyncIterator()
        _ = try #require(await newStarted.next())
        await oldGate.release()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(coordinator.isRunning)
        await newGate.release()
        try await second.value
        #expect(!coordinator.isRunning)
    }
}
