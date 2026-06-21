import Dispatch
import Foundation

struct CodexTeamsThreadSubscriptionRetryBudget {
    private let maxPendingRounds: Int
    private let maxExhaustedThreadIds: Int
    private let retryInterval: TimeInterval
    private var pendingThreadIds = Set<String>()
    private var pendingRoundByThreadId: [String: Int] = [:]
    private var exhaustedThreadIds = Set<String>()
    private var exhaustedThreadIdOrder: [String] = []
    private var deadline: DispatchTime?

    init(maxPendingRounds: Int, retryInterval: TimeInterval, maxExhaustedThreadIds: Int = 500) {
        self.maxPendingRounds = max(0, maxPendingRounds)
        self.maxExhaustedThreadIds = max(0, maxExhaustedThreadIds)
        self.retryInterval = retryInterval
    }

    mutating func markPending(_ threadId: String) -> Bool {
        if pendingThreadIds.contains(threadId) {
            return true
        }
        if exhaustedThreadIds.contains(threadId) {
            return false
        }

        let nextRound = (pendingRoundByThreadId[threadId] ?? 0) + 1
        pendingRoundByThreadId[threadId] = nextRound
        guard nextRound <= maxPendingRounds else {
            pendingThreadIds.remove(threadId)
            pendingRoundByThreadId.removeValue(forKey: threadId)
            rememberExhausted(threadId)
            clearDeadlineIfIdle()
            return false
        }

        pendingThreadIds.insert(threadId)
        if deadline == nil {
            deadline = .now() + retryInterval
        }
        return true
    }

    mutating func beginRetry(_ threadId: String) {
        pendingThreadIds.remove(threadId)
        clearDeadlineIfIdle()
    }

    mutating func clear(_ threadId: String) {
        pendingThreadIds.remove(threadId)
        pendingRoundByThreadId.removeValue(forKey: threadId)
        if exhaustedThreadIds.remove(threadId) != nil {
            exhaustedThreadIdOrder.removeAll { $0 == threadId }
        }
        clearDeadlineIfIdle()
    }

    func isPending(_ threadId: String) -> Bool {
        pendingThreadIds.contains(threadId)
    }

    func isDeferred(_ threadId: String) -> Bool {
        pendingThreadIds.contains(threadId) || exhaustedThreadIds.contains(threadId)
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

    private mutating func rememberExhausted(_ threadId: String) {
        guard maxExhaustedThreadIds > 0 else { return }
        if exhaustedThreadIds.insert(threadId).inserted {
            exhaustedThreadIdOrder.append(threadId)
        }
        while exhaustedThreadIdOrder.count > maxExhaustedThreadIds {
            exhaustedThreadIds.remove(exhaustedThreadIdOrder.removeFirst())
        }
    }
}
