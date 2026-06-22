import Foundation

/// Coalesces repeated main-thread signals into one callback after a short delay.
/// Useful for notification storms where only the latest update matters.
final class NotificationBurstCoalescer {
    typealias Cancellation = @MainActor () -> Void
    typealias Scheduler = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Cancellation

    private var delay: TimeInterval
    private let schedule: Scheduler
    private var cancelScheduledFlush: Cancellation?
    private var pendingAction: (@MainActor () -> Void)?

    init(
        delay: TimeInterval = 1.0 / 30.0,
        schedule: @escaping Scheduler = { delay, action in
            let timer = Timer(timeInterval: max(0, delay), repeats: false) { timer in
                timer.invalidate()
                MainActor.assumeIsolated {
                    action()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            return {
                timer.invalidate()
            }
        }
    ) {
        self.delay = max(0, delay)
        self.schedule = schedule
    }

    @MainActor
    func signal(delay newDelay: TimeInterval? = nil, _ action: @escaping @MainActor () -> Void) {
        precondition(Thread.isMainThread, "NotificationBurstCoalescer must be used on the main thread")
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

    @MainActor
    func flushNow() {
        cancelScheduledFlush?()
        cancelScheduledFlush = nil
        flush()
    }

    @MainActor
    private func scheduleFlushIfNeeded() {
        guard cancelScheduledFlush == nil else { return }
        let scheduledDelay = delay
        // The timer is the intended bounded coalescing delay; storing the
        // cancellation closure lets delay changes and deinit discard stale work.
        cancelScheduledFlush = schedule(scheduledDelay) { [weak self] in
            self?.flush()
        }
    }

    @MainActor
    private func flush() {
        precondition(Thread.isMainThread, "NotificationBurstCoalescer must be used on the main thread")
        cancelScheduledFlush = nil
        guard let action = pendingAction else { return }
        pendingAction = nil
        action()
        if pendingAction != nil {
            scheduleFlushIfNeeded()
        }
    }

}
