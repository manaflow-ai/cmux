import Foundation
@testable import CmuxSidebarGit

/// A virtual-time ``GitPollClock``: records every requested sleep duration
/// and suspends each sleeper until the test resumes it explicitly.
actor ManualGitPollClock: GitPollClock {
    private struct Sleeper {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private(set) var recordedDurations: [TimeInterval] = []
    private var sleepers: [Sleeper] = []
    private var cancelledIds: Set<UUID> = []
    private var sleeperWaiters: [CheckedContinuation<Void, Never>] = []

    func sleep(for duration: Duration) async throws {
        let seconds = TimeInterval(duration.components.seconds)
            + TimeInterval(duration.components.attoseconds) / 1e18
        recordedDurations.append(seconds)
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if cancelledIds.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                sleepers.append(Sleeper(id: id, continuation: continuation))
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

    /// Resumes the oldest parked sleeper.
    func resumeNext() {
        guard !sleepers.isEmpty else { return }
        sleepers.removeFirst().continuation.resume(returning: ())
    }

    var lastRecordedDuration: TimeInterval? {
        recordedDurations.last
    }

    private func cancelSleeper(id: UUID) {
        if let index = sleepers.firstIndex(where: { $0.id == id }) {
            sleepers.remove(at: index).continuation.resume(throwing: CancellationError())
        } else {
            cancelledIds.insert(id)
        }
    }
}
