/// Runs a main-actor action repeatedly without replacing its timer closure.
///
/// The scheduler owns one persistent timer handle. ``startIfIdle(every:_:)``
/// refuses to replace a running action, and ``cancel()`` drops the action before
/// disarming the timer. Callers that capture their owner must cancel at the
/// corresponding lifecycle boundary.
@MainActor
public final class MainActorRepeatingActionScheduler {
    private var interval: Duration = .zero
    private var action: (@MainActor () -> Void)?
    private lazy var timer = MainActorCoalescingDeadlineTimer(owner: self) { scheduler in
        scheduler.fire()
    }

    /// Creates an idle repeating-action scheduler.
    public init() {}

    /// Whether an action is currently scheduled to repeat.
    public var isRunning: Bool {
        action != nil
    }

    /// Starts an action only when the scheduler is idle.
    ///
    /// The first action is enqueued immediately. Later actions are scheduled
    /// one `interval` after the preceding timer fires.
    ///
    /// - Parameters:
    ///   - interval: The delay between actions, clamped to zero.
    ///   - action: Main-actor work to repeat until ``cancel()`` is called.
    public func startIfIdle(
        every interval: Duration,
        _ action: @escaping @MainActor () -> Void
    ) {
        guard self.action == nil else { return }
        self.interval = max(interval, .zero)
        self.action = action
        timer.schedule(after: .zero)
    }

    /// Stops repeating and releases the current action.
    public func cancel() {
        action = nil
        timer.cancel()
    }

    private func fire() {
        guard let action else { return }
        timer.schedule(after: interval)
        action()
    }
}
