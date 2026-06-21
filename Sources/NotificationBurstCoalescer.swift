import Foundation

/// Coalesces repeated main-thread signals into one callback after a short delay.
/// Useful for notification storms where only the latest update matters.
final class NotificationBurstCoalescer {
    private var delay: TimeInterval
    private let sleep: @Sendable (UInt64) async throws -> Void
    private var flushTask: Task<Void, Never>?
    private var pendingAction: (() -> Void)?

    init(
        delay: TimeInterval = 1.0 / 30.0,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.delay = max(0, delay)
        self.sleep = sleep
    }

    deinit {
        flushTask?.cancel()
    }

    func signal(delay newDelay: TimeInterval? = nil, _ action: @escaping () -> Void) {
        precondition(Thread.isMainThread, "NotificationBurstCoalescer must be used on the main thread")
        let previousDelay = delay
        if let newDelay {
            delay = max(0, newDelay)
        }
        pendingAction = action
        if flushTask != nil, delay != previousDelay {
            flushTask?.cancel()
            flushTask = nil
        }
        scheduleFlushIfNeeded()
    }

    private func scheduleFlushIfNeeded() {
        guard flushTask == nil else { return }
        let scheduledDelay = delay
        // The sleep is the intended bounded coalescing delay; storing the task
        // lets delay changes and deinit cancel it instead of leaving stale work.
        flushTask = Task { @MainActor [weak self, sleep] in
            do {
                try await sleep(Self.nanoseconds(for: scheduledDelay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func flush() {
        precondition(Thread.isMainThread, "NotificationBurstCoalescer must be used on the main thread")
        flushTask = nil
        guard let action = pendingAction else { return }
        pendingAction = nil
        action()
        if pendingAction != nil {
            scheduleFlushIfNeeded()
        }
    }

    private static func nanoseconds(for delay: TimeInterval) -> UInt64 {
        let nanoseconds = delay * 1_000_000_000
        guard nanoseconds.isFinite, nanoseconds > 0 else { return 0 }
        return UInt64(min(nanoseconds.rounded(.up), Double(UInt64.max)))
    }
}
