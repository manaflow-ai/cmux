import Foundation
@testable import CmuxIrohTransport

final class HostRegistrationRenewalClock: CmxIrohRelayClock, @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    private var deadlines: [Date] = []
    private var sleepers: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var sleepWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationCount = 0

    init(now: Date) {
        date = now
    }

    func now() -> Date {
        lock.withLock { date }
    }

    func sleep(until deadline: Date) async throws {
        let id = UUID()
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            deadlines.append(deadline)
            defer { sleepWaiters.removeAll() }
            return sleepWaiters
        }
        for waiter in waiters { waiter.resume() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { sleepers[id] = continuation }
                if Task.isCancelled { cancel(id: id) }
            }
        } onCancel: {
            cancel(id: id)
        }
    }

    func advance(to newDate: Date) {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            date = newDate
            defer { sleepers.removeAll() }
            return Array(sleepers.values)
        }
        for continuation in continuations { continuation.resume() }
    }

    func observedSleepDeadlines() -> [Date] {
        lock.withLock { deadlines }
    }

    func waitUntilSleeping() async {
        await waitUntilSleepCount(1)
    }

    func waitUntilSleepCount(_ count: Int) async {
        let shouldWait = lock.withLock { deadlines.count < count }
        guard shouldWait else { return }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if deadlines.count < count {
                    sleepWaiters.append(continuation)
                    return false
                }
                return true
            }
            if resumeNow { continuation.resume() }
        }
    }

    func observedCancellationCount() -> Int {
        lock.withLock { cancellationCount }
    }

    private func cancel(id: UUID) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            guard let continuation = sleepers.removeValue(forKey: id) else { return nil }
            cancellationCount += 1
            return continuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}
