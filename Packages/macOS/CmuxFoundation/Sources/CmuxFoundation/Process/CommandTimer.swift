import Foundation

/// Activated one-shot timer used by a command deadline or SIGKILL grace period.
///
/// Safety: `DispatchSourceTimer` is thread-safe, immutable after initialization,
/// and only receives idempotent cancellation calls across callback threads.
final class CommandTimer: @unchecked Sendable {
    private let source: any DispatchSourceTimer

    init(
        deadline: DispatchTime,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) {
        source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: deadline)
        source.setEventHandler(handler: handler)
        source.activate()
    }

    deinit {
        source.cancel()
    }

    func cancel() {
        source.cancel()
    }
}
