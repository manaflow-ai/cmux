import Foundation

/// Re-runs attachment resolution for a machine's open panes after a failed
/// pass, on the provider's own schedule instead of waiting for the next
/// external refresh edge.
///
/// One scheduler per provider: every failed pass records one more failure and
/// arms one retry; a successful pass resets the count. The delay is a genuine
/// wait, driven by an injected clock so tests advance virtual time.
@MainActor
final class CloudTerminalAttachmentRetryScheduler {
    private let policy: CloudTerminalAttachmentRetryPolicy
    private let clock: any Clock<Duration>
    private var task: Task<Void, Never>?
    private(set) var failures = 0

    init(
        policy: CloudTerminalAttachmentRetryPolicy = .background,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.policy = policy
        self.clock = clock
    }

    /// Whether a retry is armed and has not fired yet.
    var isPending: Bool { task != nil }

    /// Records a failed pass and arms `retry` after the policy's delay. An
    /// armed retry is replaced, never duplicated. Returns the delay chosen.
    @discardableResult
    func scheduleRetry(_ retry: @escaping @MainActor () -> Void) -> Duration {
        failures += 1
        let delay = policy.cappedDelay(afterFailures: failures)
        task?.cancel()
        task = Task { @MainActor [weak self, clock] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            retry()
        }
        return delay
    }

    /// A successful pass: nothing to retry, and the backoff starts over.
    func reset() {
        task?.cancel()
        task = nil
        failures = 0
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
