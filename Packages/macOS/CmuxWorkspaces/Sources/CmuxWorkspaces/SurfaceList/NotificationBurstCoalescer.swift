public import Foundation

/// Coalesces repeated main-thread signals into one callback after a short delay.
/// Useful for notification storms where only the latest update matters.
///
/// This is the panel-title scheduler for ``SurfaceMetadataCoordinator``: a
/// faithful copy of the app-target `NotificationBurstCoalescer` (which other
/// window-chrome call sites still use), moved here so the coordinator owns its
/// own flush timing instead of reaching back into the app target through a host
/// seam. Behavior is byte-identical to the legacy app-target type: the same
/// `1.0 / 30.0` default delay, the same single-pending-action coalescing, the
/// same re-arm when a flush enqueues another action, and the same
/// `DispatchQueue.main.asyncAfter` timer.
@MainActor
final class NotificationBurstCoalescer: TitleFlushScheduling {
    private let delay: TimeInterval
    private var isFlushScheduled = false
    private var pendingAction: (() -> Void)?

    /// Creates a coalescer that flushes `delay` seconds after the first signal
    /// in a burst. A negative delay is clamped to zero.
    public init(delay: TimeInterval = 1.0 / 30.0) {
        self.delay = max(0, delay)
    }

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
