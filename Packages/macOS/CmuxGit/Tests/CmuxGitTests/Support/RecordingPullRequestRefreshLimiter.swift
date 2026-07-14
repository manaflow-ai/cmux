import Foundation
@testable import CmuxGit

actor RecordingPullRequestRefreshLimiter: PullRequestPanelRefreshLimiting {
    private let probe: PullRequestRefreshSchedulingProbe
    private var activeCount = 0
    private var waiters: [RecordingPullRequestRefreshWaiter] = []
    private var cancellationCount = 0
    private var cancellationWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    init(probe: PullRequestRefreshSchedulingProbe) {
        self.probe = probe
    }

    func acquire() async -> Bool {
        let id = UUID()
        guard !Task.isCancelled else { return false }
        if activeCount < 2 {
            activeCount += 1
            return true
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(RecordingPullRequestRefreshWaiter(id: id, continuation: continuation))
                    Task { await probe.queuedRefreshObserved() }
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    func release() {
        guard activeCount > 0 else { return }
        if waiters.isEmpty {
            activeCount -= 1
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    func waitForCancellationCount(_ count: Int) async {
        guard cancellationCount < count else { return }
        await withCheckedContinuation { cancellationWaiters[count, default: []].append($0) }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
        cancellationCount += 1
        let completedCounts = cancellationWaiters.keys.filter { $0 <= cancellationCount }
        for count in completedCounts {
            cancellationWaiters.removeValue(forKey: count)?.forEach { $0.resume() }
        }
    }
}
