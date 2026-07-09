public import Foundation

/// Coalesces repeated main-thread signals into one callback after a short delay.
///
/// Useful for notification storms where only the latest update matters: each
/// `signal(_:)` replaces the pending action and, if no flush is already
/// scheduled, schedules one `delay` seconds out. When the flush fires it runs
/// the most recently supplied action; if a new signal arrived while flushing,
/// it reschedules so the latest action is never dropped.
///
/// All access must happen on the main thread; the type is `@MainActor` and
/// `signal(_:)` and the flush both retain a `precondition(Thread.isMainThread)`
/// to preserve the original runtime contract.
@MainActor
public final class NotificationBurstCoalescer {
    private let delay: TimeInterval
    private var isFlushScheduled = false
    private var pendingAction: (() -> Void)?

    /// Creates a coalescer that fires at most once per `delay` seconds.
    /// - Parameter delay: Minimum interval between flushes. Negative values are
    ///   clamped to zero. Defaults to one 30 Hz frame (`1.0 / 30.0`).
    public init(delay: TimeInterval = 1.0 / 30.0) {
        self.delay = max(0, delay)
    }

    /// Records `action` as the pending work and schedules a flush if one is not
    /// already pending. Must be called on the main thread.
    public func signal(_ action: @escaping () -> Void) {
        precondition(Thread.isMainThread, "NotificationBurstCoalescer must be used on the main thread")
        pendingAction = action
        scheduleFlushIfNeeded()
    }

    private func scheduleFlushIfNeeded() {
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        precondition(Thread.isMainThread, "NotificationBurstCoalescer must be used on the main thread")
        isFlushScheduled = false
        guard let action = pendingAction else { return }
        pendingAction = nil
        action()
        if pendingAction != nil {
            scheduleFlushIfNeeded()
        }
    }
}
