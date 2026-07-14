import Foundation

actor PullRequestRefreshSchedulingProbe {
    private(set) var maximumActiveBranchViewCount = 0
    private(set) var startedBranches: Set<String> = []
    private var activeBranchViewCount = 0
    private var branchViewsAreReleased = false
    private var branchViewReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var startedCountWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var thirdAttempt: PullRequestRefreshThirdAttempt?
    private var thirdAttemptWaiters: [CheckedContinuation<PullRequestRefreshThirdAttempt, Never>] = []

    func branchViewStarted(branch: String) {
        startedBranches.insert(branch)
        activeBranchViewCount += 1
        maximumActiveBranchViewCount = max(maximumActiveBranchViewCount, activeBranchViewCount)
        resumeStartedCountWaiters()
        if startedBranches.count >= 3 {
            recordThirdAttempt(.branchStarted)
        }
    }

    func branchViewEnded() {
        activeBranchViewCount -= 1
    }

    func queuedRefreshObserved() {
        recordThirdAttempt(.queued)
    }

    func waitForStartedBranchCount(_ count: Int) async {
        guard startedBranches.count < count else { return }
        await withCheckedContinuation { continuation in
            startedCountWaiters[count, default: []].append(continuation)
        }
    }

    func waitForThirdAttempt() async -> PullRequestRefreshThirdAttempt {
        if let thirdAttempt { return thirdAttempt }
        return await withCheckedContinuation { thirdAttemptWaiters.append($0) }
    }

    func waitUntilBranchViewsAreReleased() async {
        guard !branchViewsAreReleased else { return }
        await withCheckedContinuation { branchViewReleaseWaiters.append($0) }
    }

    func releaseBranchViews() {
        branchViewsAreReleased = true
        let waiters = branchViewReleaseWaiters
        branchViewReleaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func recordThirdAttempt(_ attempt: PullRequestRefreshThirdAttempt) {
        guard thirdAttempt == nil else { return }
        thirdAttempt = attempt
        let waiters = thirdAttemptWaiters
        thirdAttemptWaiters.removeAll()
        waiters.forEach { $0.resume(returning: attempt) }
    }

    private func resumeStartedCountWaiters() {
        let completedCounts = startedCountWaiters.keys.filter { $0 <= startedBranches.count }
        for count in completedCounts {
            startedCountWaiters.removeValue(forKey: count)?.forEach { $0.resume() }
        }
    }
}
