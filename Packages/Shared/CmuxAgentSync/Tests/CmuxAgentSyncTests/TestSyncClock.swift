import CmuxAgentSync
import Foundation

actor TestSyncClock: SyncClock {
    private struct Waiter {
        let deadline: Int64
        let continuation: AsyncStream<Void>.Continuation
    }

    private var currentMilliseconds: Int64
    private var waiters: [UUID: Waiter]
    private var requestedSleeps: [Int]

    init(currentMilliseconds: Int64 = 0) {
        self.currentMilliseconds = currentMilliseconds
        waiters = [:]
        requestedSleeps = []
    }

    func nowMilliseconds() async -> Int64 {
        currentMilliseconds
    }

    func sleep(milliseconds: Int) async {
        requestedSleeps.append(milliseconds)
        guard milliseconds > 0 else { return }

        let id = UUID()
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeWaiter(id: id) }
        }
        waiters[id] = Waiter(
            deadline: currentMilliseconds + Int64(milliseconds),
            continuation: pair.continuation
        )
        for await _ in pair.stream {
            break
        }
    }

    func advance(milliseconds: Int) {
        currentMilliseconds += Int64(milliseconds)
        let dueIDs = waiters.compactMap { id, waiter in
            waiter.deadline <= currentMilliseconds ? id : nil
        }
        for id in dueIDs {
            guard let waiter = waiters.removeValue(forKey: id) else { continue }
            waiter.continuation.yield()
            waiter.continuation.finish()
        }
    }

    func sleepRequests() -> [Int] {
        requestedSleeps
    }

    func pendingSleepCount() -> Int {
        waiters.count
    }

    private func removeWaiter(id: UUID) {
        waiters[id] = nil
    }
}
