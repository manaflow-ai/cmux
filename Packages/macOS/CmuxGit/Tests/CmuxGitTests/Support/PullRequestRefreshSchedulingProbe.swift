import Foundation

actor PullRequestRefreshSchedulingProbe {
    enum ThirdAttempt: Equatable {
        case branchStarted
        case queued
    }

    private(set) var maximumActiveBranchViewCount = 0
    private(set) var startedBranches: Set<String> = []
    private var activeBranchViewCount = 0
    private var branchViewsAreReleased = false
    private var branchViewReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var startedCountWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var thirdAttempt: ThirdAttempt?
    private var thirdAttemptWaiters: [CheckedContinuation<ThirdAttempt, Never>] = []

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

    func waitForThirdAttempt() async -> ThirdAttempt {
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

    private func recordThirdAttempt(_ attempt: ThirdAttempt) {
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
