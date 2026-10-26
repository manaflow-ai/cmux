import CmuxNextDaemon
import Foundation

/// Reads the machine list again after it failed (#25595). The list is read at sign-in or launch,
/// after a mutation, on app activation and on wake; a launch while offline or while the API was down
/// left every Cloud workspace without its machine (no terminal, no browser route) until the person
/// switched apps. A failed read is now tried again on a capped backoff (``RetryPolicy/cloudList``),
/// a bounded number of times: after that only the events above read it, never a fixed period.
@MainActor
final class CloudListRetry {
    private let clock: any Clock<Duration>
    private var pacer = RetryPacer(.cloudList)
    private var pending: Task<Void, Never>?

    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    /// Whether a retry waits now.
    var isScheduled: Bool { pending != nil }

    /// A read failed: `read` runs again after the next backoff step, unless the budget is spent.
    /// A retry already waiting stays the only one.
    func failed(read: @escaping @MainActor () async -> Void) {
        guard pending == nil, let delay = pacer.failed() else { return }
        let clock = clock
        // task-owner: one retry at a time, cancelled by `succeeded` and `cancel`
        pending = Task { [weak self] in
            // wakeup-allow: one capped backoff step after a failed list read, a bounded number of times
            guard (try? await clock.sleep(for: delay)) != nil, let self, !Task.isCancelled else { return }
            pending = nil
            await read()
        }
    }

    /// A read landed, or the account's machines were dropped (sign-out, another account): no retry
    /// waits and the next failure starts the backoff over.
    func reset() {
        cancel()
        pacer.reset()
    }

    /// No retry waits (signed out, the machines dropped).
    func cancel() {
        pending?.cancel()
        pending = nil
    }
}

extension RetryPolicy {
    /// A failed Cloud machine list: 1 s growing to 30 s, 10 timed attempts (about 3 minutes).
    static let cloudList = RetryPolicy(initial: .seconds(1), maximum: .seconds(30), timedRetries: 10)
}

extension CloudService {
    nonisolated static func listIsCurrent(loadedAt: ContinuousClock.Instant?, loadedFor: [String?]?, account: [String?], now: ContinuousClock.Instant, within age: Duration) -> Bool {
        guard let loadedAt, loadedFor == account else { return false }
        return loadedAt.duration(to: now) < age
    }
}
