import Foundation
@testable import CmuxSidebarGit

/// A virtual-time ``GitPollClock``: records every requested sleep duration
/// and suspends each sleeper until the test resumes it explicitly.
actor ManualGitPollClock: GitPollClock {
    private struct Sleeper {
        let id: UUID
        let duration: TimeInterval
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct RecordedDurationWaiter {
        let duration: TimeInterval
        let minimumCount: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private(set) var recordedDurations: [TimeInterval] = []
    private var sleepers: [Sleeper] = []
    private var cancelledIds: Set<UUID> = []
    private var sleeperWaiters: [CheckedContinuation<Void, Never>] = []
    private var recordedDurationWaitersByID: [UUID: RecordedDurationWaiter] = [:]

    func sleep(for duration: Duration) async throws {
        let seconds = TimeInterval(duration.components.seconds)
            + TimeInterval(duration.components.attoseconds) / 1e18
        recordedDurations.append(seconds)
        resumeSatisfiedRecordedDurationWaiters()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if cancelledIds.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                sleepers.append(Sleeper(id: id, duration: seconds, continuation: continuation))
                while !sleeperWaiters.isEmpty {
                    sleeperWaiters.removeFirst().resume()
                }
            }
        } onCancel: {
            Task {
                await self.cancelSleeper(id: id)
            }
        }
    }

    /// Suspends until at least one sleeper is parked on the clock.
    func waitForSleeper() async {
        while sleepers.isEmpty {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                sleeperWaiters.append(continuation)
            }
        }
    }

    /// Suspends until a sleeper with the requested virtual duration is parked.
    func waitForSleeper(duration: TimeInterval) async {
        while !sleepers.contains(where: { $0.duration == duration }) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                sleeperWaiters.append(continuation)
            }
        }
    }

    nonisolated func waitForRecordedDuration(
        _ duration: TimeInterval,
        count minimumCount: Int,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.waitForRecordedDuration(duration, count: minimumCount)
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return false
                } catch {
                    return false
                }
            }
            let didRecord = await group.next() ?? false
            group.cancelAll()
            return didRecord
        }
    }

    /// Resumes the oldest parked sleeper.
    func resumeNext() {
        guard !sleepers.isEmpty else { return }
        sleepers.removeFirst().continuation.resume(returning: ())
    }

    /// Resumes the oldest parked sleeper with the requested duration.
    @discardableResult
    func resumeFirst(duration: TimeInterval) -> Bool {
        guard let index = sleepers.firstIndex(where: { $0.duration == duration }) else {
            return false
        }
        sleepers.remove(at: index).continuation.resume(returning: ())
        return true
    }

    /// Compatibility spelling used by the snapshot-coordination tests.
    func resumeNext(duration: TimeInterval) {
        _ = resumeFirst(duration: duration)
    }

    var lastRecordedDuration: TimeInterval? {
        recordedDurations.last
    }

    var pendingSleeperCount: Int {
        sleepers.count
    }

    private func cancelSleeper(id: UUID) {
        if let index = sleepers.firstIndex(where: { $0.id == id }) {
            sleepers.remove(at: index).continuation.resume(throwing: CancellationError())
        } else {
            cancelledIds.insert(id)
        }
    }

    private func waitForRecordedDuration(
        _ duration: TimeInterval,
        count minimumCount: Int
    ) async -> Bool {
        if recordedDurationCount(duration) >= minimumCount {
            return true
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                recordedDurationWaitersByID[waiterID] = RecordedDurationWaiter(
                    duration: duration,
                    minimumCount: minimumCount,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task {
                await self.cancelRecordedDurationWaiter(waiterID)
            }
        }
    }

    private func cancelRecordedDurationWaiter(_ waiterID: UUID) {
        recordedDurationWaitersByID.removeValue(forKey: waiterID)?
            .continuation.resume(returning: false)
    }

    private func resumeSatisfiedRecordedDurationWaiters() {
        let satisfiedWaiterIDs = recordedDurationWaitersByID.compactMap { id, waiter in
            recordedDurationCount(waiter.duration) >= waiter.minimumCount ? id : nil
        }
        for waiterID in satisfiedWaiterIDs {
            recordedDurationWaitersByID.removeValue(forKey: waiterID)?
                .continuation.resume(returning: true)
        }
    }

    private func recordedDurationCount(_ duration: TimeInterval) -> Int {
        recordedDurations.lazy.filter { $0 == duration }.count
    }
}
