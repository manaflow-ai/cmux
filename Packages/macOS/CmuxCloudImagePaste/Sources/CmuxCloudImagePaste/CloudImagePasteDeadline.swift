import Dispatch

/// Delivers one cancellable upload deadline without blocking an async task.
///
/// The dispatch source is intentional: the deadline is a transport signal,
/// not a task used to synchronize state. Cancellation is safe from either the
/// coordinator or the timer callback.
// @unchecked Sendable is safe because DispatchSourceTimer cancellation and
// handler replacement are thread-safe; this type has no other mutable state.
final class CloudImagePasteDeadline: @unchecked Sendable {
    private let timer: any DispatchSourceTimer

    init(duration: Duration, action: @escaping @MainActor @Sendable () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.dispatchInterval(for: duration), repeating: .never)
        timer.setEventHandler { [action] in
            MainActor.assumeIsolated { action() }
        }
        timer.resume()
        self.timer = timer
    }

    func cancel() {
        timer.setEventHandler {}
        timer.cancel()
    }

    private static func dispatchInterval(for duration: Duration) -> DispatchTimeInterval {
        let components = duration.components
        guard components.seconds >= 0 else { return .nanoseconds(0) }
        let seconds = min(components.seconds, Int64(Int.max / 1_000_000_000))
        let nanos = seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
        return .nanoseconds(Int(min(nanos, Int64(Int.max))))
    }

    deinit {
        timer.setEventHandler {}
        timer.cancel()
    }
}
