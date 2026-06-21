import Foundation

/// Coalesces repeated main-thread signals into one callback after a short delay.
/// Useful for notification storms where only the latest update matters.
final class NotificationBurstCoalescer {
    private var delay: TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> (() -> Void)
    private var cancelScheduledFlush: (() -> Void)?
    private var pendingAction: (() -> Void)?

    init(
        delay: TimeInterval = 1.0 / 30.0,
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> (() -> Void) = { delay, action in
            let timer = Timer(timeInterval: max(0, delay), repeats: false) { timer in
                timer.invalidate()
                action()
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

    deinit {
        cancelScheduledFlush?()
    }

    func signal(delay newDelay: TimeInterval? = nil, _ action: @escaping () -> Void) {
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

    private func scheduleFlushIfNeeded() {
        guard cancelScheduledFlush == nil else { return }
        let scheduledDelay = delay
        // The timer is the intended bounded coalescing delay; storing the
        // cancellation closure lets delay changes and deinit discard stale work.
        cancelScheduledFlush = schedule(scheduledDelay) { [weak self] in
            self?.flush()
        }
    }

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
