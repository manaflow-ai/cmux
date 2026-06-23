public import Foundation

/// Coalesces repeated main-thread signals into one callback after a short delay.
///
/// Faithful copy of the app-target `NotificationBurstCoalescer` used by the
/// window-chrome titlebar-text scheduler (`1.0 / 30.0` default delay, single
/// pending action, re-arm when a flush enqueues another action,
/// `DispatchQueue.main.asyncAfter` timer). Lifted into the package alongside the
/// window-chrome cluster so `WindowChromeController` owns its own flush timing
/// without an app-target dependency. Behavior is byte-identical to the legacy
/// type.
@MainActor
public final class WindowChromeTitlebarTextCoalescer {
    private let delay: TimeInterval
    private var isFlushScheduled = false
    private var pendingAction: (() -> Void)?

    /// Creates a coalescer that flushes `delay` seconds after the first signal in
    /// a burst. A negative delay is clamped to zero.
    public init(delay: TimeInterval = 1.0 / 30.0) {
        self.delay = max(0, delay)
    }

    /// Records the latest action and arms the flush if not already scheduled.
    public func signal(_ action: @escaping () -> Void) {
        precondition(Thread.isMainThread, "WindowChromeTitlebarTextCoalescer must be used on the main thread")
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
        precondition(Thread.isMainThread, "WindowChromeTitlebarTextCoalescer must be used on the main thread")
        isFlushScheduled = false
        guard let action = pendingAction else { return }
        pendingAction = nil
        action()
        if pendingAction != nil {
            scheduleFlushIfNeeded()
        }
    }
}
