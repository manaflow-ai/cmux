import Foundation

/// Coalesces repeated main-thread signals into one callback after a short delay.
/// Useful for notification storms where only the latest update matters.
@MainActor
final class NotificationBurstCoalescer {
    typealias Cancellation = @MainActor () -> Void
    typealias Scheduler = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Cancellation

    private var delay: TimeInterval
    private let schedule: Scheduler
    private var cancelScheduledFlush: Cancellation?
    private var pendingAction: (@MainActor () -> Void)?

    @MainActor
    init(
        delay: TimeInterval = 1.0 / 30.0,
        schedule: @escaping Scheduler = { delay, action in
            let boundedDelay = max(0, delay)
            let maximumDelay = Double(Int.max) / 1_000_000_000.0
            let nanoseconds = Int((min(boundedDelay, maximumDelay) * 1_000_000_000.0).rounded(.up))
            // One-shot coalescing is an intentional sync deadline; tests inject `schedule`.
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + .nanoseconds(nanoseconds))
            timer.setEventHandler {
                MainActor.assumeIsolated {
                    action()
                }
            }
            timer.resume()
            return {
                timer.setEventHandler {}
                timer.cancel()
            }
        }
    ) {
        self.delay = max(0, delay)
        self.schedule = schedule
    }

    func signal(delay newDelay: TimeInterval? = nil, _ action: @escaping @MainActor () -> Void) {
        let previousDelay = delay
        if let newDelay {
            delay = max(0, newDelay)
        }
        pendingAction = action
        if cancelScheduledFlush != nil, delay != previousDelay {
            cancelScheduledFlush?()
            cancelScheduledFlush = nil
        }
        scheduleFlushIfNeeded()
    }

    /// Like `signal`, but resets the delay window on every call so the action
    /// fires only after calls stop for `delay` (trailing debounce, not the
    /// fire-from-first-signal throttle that `signal` provides).
    func debounce(delay newDelay: TimeInterval? = nil, _ action: @escaping @MainActor () -> Void) {
        if let newDelay {
            delay = max(0, newDelay)
        }
        pendingAction = action
        cancelScheduledFlush?()
        cancelScheduledFlush = nil
        scheduleFlushIfNeeded()
    }

    func flushNow() {
        cancelScheduledFlush?()
        cancelScheduledFlush = nil
        flush()
    }

    /// Drops the pending action and any scheduled flush without running it.
    func cancel() {
        cancelScheduledFlush?()
        cancelScheduledFlush = nil
        pendingAction = nil
    }

    private func scheduleFlushIfNeeded() {
        guard cancelScheduledFlush == nil else { return }
        let scheduledDelay = delay
        cancelScheduledFlush = schedule(scheduledDelay) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        cancelScheduledFlush = nil
        guard let action = pendingAction else { return }
        pendingAction = nil
        action()
        if pendingAction != nil {
            scheduleFlushIfNeeded()
        }
    }

}
