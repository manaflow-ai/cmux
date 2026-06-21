import Dispatch
import Foundation

struct CodexTeamsThreadSubscriptionRetryBudget {
    private let maxPendingRounds: Int
    private let retryInterval: TimeInterval
    private var pendingThreadIds = Set<String>()
    private var pendingRoundByThreadId: [String: Int] = [:]
    private var deadline: DispatchTime?

    init(maxPendingRounds: Int, retryInterval: TimeInterval) {
        self.maxPendingRounds = max(0, maxPendingRounds)
        self.retryInterval = retryInterval
    }

    mutating func markPending(_ threadId: String) -> Bool {
        let nextRound = (pendingRoundByThreadId[threadId] ?? 0) + 1
        pendingRoundByThreadId[threadId] = nextRound
        guard nextRound <= maxPendingRounds else {
            pendingThreadIds.remove(threadId)
            clearDeadlineIfIdle()
            return false
        }

        pendingThreadIds.insert(threadId)
        if deadline == nil {
            deadline = .now() + retryInterval
        }
        return true
    }

    mutating func clear(_ threadId: String) {
        pendingThreadIds.remove(threadId)
        pendingRoundByThreadId.removeValue(forKey: threadId)
        clearDeadlineIfIdle()
    }

    mutating func resetDeadline() {
        deadline = nil
    }

    func pendingThreadIdSnapshot() -> [String] {
        Array(pendingThreadIds)
    }

    func pendingRetryTimeout() -> TimeInterval? {
        guard !pendingThreadIds.isEmpty,
              let deadline else {
            return nil
        }
        let now = DispatchTime.now().uptimeNanoseconds
        if deadline.uptimeNanoseconds <= now {
            return 0
        }
        return TimeInterval(deadline.uptimeNanoseconds - now) / 1_000_000_000
    }

    private mutating func clearDeadlineIfIdle() {
        if pendingThreadIds.isEmpty {
            deadline = nil
        }
    }
}
