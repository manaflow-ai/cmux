public import Foundation

/// Coalesces keyed values until a burst is quiet, while bounding total deferral.
///
/// A later submission for the same key replaces the earlier value. The quiet
/// deadline is rearmed for every submission; the maximum deadline is anchored
/// to the first submission in the batch. Whichever deadline fires first drains
/// the batch once on the main actor.
@MainActor
public final class LatestWinsBatcher<Key: Hashable, Value> {
    /// Cancels a scheduled deadline.
    public typealias Cancellation = @MainActor () -> Void

    /// Schedules one main-actor action after the requested delay.
    public typealias Scheduler = @MainActor (
        TimeInterval,
        @escaping @MainActor () -> Void
    ) -> Cancellation

    typealias DeadlineNow = @MainActor () -> ContinuousClock.Instant
    typealias DeadlineSleep = @MainActor (ContinuousClock.Instant) async throws -> Void
    typealias DeadlineTaskStarter = @MainActor (
        @escaping @MainActor () async -> Void
    ) -> Cancellation

    private let quietDelay: TimeInterval
    private let maximumDelay: TimeInterval
    private let schedule: Scheduler
    private var pending: [Key: Value] = [:]
    private var cancelQuietDeadline: Cancellation?
    private var cancelMaximumDeadline: Cancellation?

    /// Creates a latest-wins batcher.
    ///
    /// - Parameters:
    ///   - quietDelay: Time without another submission before the batch drains.
    ///   - maximumDelay: Maximum time from the first submission to the drain.
    ///   - scheduler: Deadline scheduler. Tests inject a virtual scheduler.
    public init(
        quietDelay: TimeInterval,
        maximumDelay: TimeInterval,
        scheduler: @escaping Scheduler
    ) {
        self.quietDelay = max(0, quietDelay)
        self.maximumDelay = max(0, maximumDelay)
        self.schedule = scheduler
    }

    /// Creates a batcher backed by cancellable continuous-clock deadlines.
    ///
    /// - Parameters:
    ///   - quietDelay: Time without another submission before the batch drains.
    ///   - maximumDelay: Maximum time from the first submission to the drain.
    public convenience init(
        quietDelay: TimeInterval,
        maximumDelay: TimeInterval
    ) {
        self.init(
            quietDelay: quietDelay,
            maximumDelay: maximumDelay,
            scheduler: LatestWinsBatcher.systemScheduler
        )
    }

    /// Adds or replaces one keyed value and schedules a single batch drain.
    ///
    /// - Parameters:
    ///   - value: Latest value for `key`.
    ///   - key: Stable identity whose pending value should be replaced.
    ///   - drain: Consumer invoked with the complete pending batch.
    public func submit(
        _ value: Value,
        for key: Key,
        drain: @escaping @MainActor ([Key: Value]) -> Void
    ) {
        pending[key] = value

        cancelQuietDeadline?()
        cancelQuietDeadline = schedule(quietDelay) { [weak self] in
            self?.drain(using: drain)
        }

        guard cancelMaximumDeadline == nil else { return }
        cancelMaximumDeadline = schedule(maximumDelay) { [weak self] in
            self?.drain(using: drain)
        }
    }

    /// Immediately drains the current batch, if any.
    ///
    /// - Parameter drain: Consumer invoked with the complete pending batch.
    public func flushNow(_ drain: @MainActor ([Key: Value]) -> Void) {
        self.drain(using: drain)
    }

    /// Discards pending values and cancels both deadlines.
    public func cancel() {
        cancelDeadlines()
        pending.removeAll(keepingCapacity: true)
    }

    private func drain(using consumer: @MainActor ([Key: Value]) -> Void) {
        guard !pending.isEmpty else {
            cancelDeadlines()
            return
        }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        cancelDeadlines()
        consumer(batch)
    }

    private func cancelDeadlines() {
        cancelQuietDeadline?()
        cancelMaximumDeadline?()
        cancelQuietDeadline = nil
        cancelMaximumDeadline = nil
    }

    private static func systemScheduler(
        delay: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> Cancellation {
        let clock = ContinuousClock()
        return absoluteDeadlineScheduler(
            now: { clock.now },
            sleepUntil: { deadline in
                try await clock.sleep(until: deadline)
            },
            startTask: { operation in
                let task = Task { @MainActor in
                    await operation()
                }
                return { task.cancel() }
            }
        )(delay, action)
    }

    /// Builds a scheduler whose deadline is captured before its task is
    /// enqueued. Main-actor congestion can delay task startup, so computing the
    /// delay inside the task would extend both quiet and maximum batching bounds.
    static func absoluteDeadlineScheduler(
        now: @escaping DeadlineNow,
        sleepUntil: @escaping DeadlineSleep,
        startTask: @escaping DeadlineTaskStarter
    ) -> Scheduler {
        { delay, action in
            let deadline = now().advanced(by: .seconds(max(0, delay)))
            return startTask {
                do {
                    try await sleepUntil(deadline)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                action()
            }
        }
    }
}
