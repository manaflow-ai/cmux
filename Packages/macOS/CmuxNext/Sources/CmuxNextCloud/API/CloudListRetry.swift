import CmuxNextWakeups

/// Reads the machine list again after it failed (#25595). The list is read at sign-in or launch,
/// after a mutation, on app activation and on wake; a launch while offline or while the API was down
/// left every Cloud workspace without its machine (no terminal, no browser route) until the person
/// switched apps. A failed read is now tried again on a capped backoff (1 s growing to 30 s), at
/// most ``timedRetries`` times: after that only the events above read it, never a fixed period.
@MainActor
public final class CloudListRetry {
    /// Timed retries before only events read the list again (about 3 minutes).
    public static let timedRetries = 10

    private let clock: any Clock<Duration>
    private var backoff = Backoff(initial: .seconds(1), maximum: .seconds(30))
    private var failures = 0
    private var pending: Task<Void, Never>?

    public init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    /// Whether a retry waits now.
    public var isScheduled: Bool { pending != nil }

    /// A read failed: `read` runs again after the next backoff step, unless the budget is spent.
    /// A retry already waiting stays the only one.
    public func failed(read: @escaping @MainActor () async -> Void) {
        guard pending == nil, failures < Self.timedRetries else { return }
        failures += 1
        let delay = backoff.next(), clock = clock
        // task-owner: one retry at a time, cancelled by `reset` and `cancel`
        pending = Task { [weak self] in
            // wakeup-allow: one capped backoff step after a failed list read, a bounded number of times
            guard (try? await clock.sleep(for: delay)) != nil, let self, !Task.isCancelled else { return }
            pending = nil
            await read()
        }
    }

    /// A read landed, or the account's machines were dropped (sign-out, another account): no retry
    /// waits and the next failure starts the backoff over.
    public func reset() {
        cancel()
        failures = 0
        backoff.reset()
    }

    /// No retry waits (signed out, the machines dropped).
    public func cancel() {
        pending?.cancel()
        pending = nil
    }

    /// Whether the list loaded at `loadedAt` for `loadedFor` is the current account's and younger than `age`.
    public nonisolated static func listIsCurrent(loadedAt: ContinuousClock.Instant?, loadedFor: [String?]?, account: [String?], now: ContinuousClock.Instant, within age: Duration) -> Bool {
        guard let loadedAt, loadedFor == account else { return false }
        return loadedAt.duration(to: now) < age
    }
}
