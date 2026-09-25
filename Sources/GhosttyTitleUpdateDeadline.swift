import Dispatch
import Foundation

/// Owns one off-main title-publication deadline.
///
/// A one-shot dispatch source is intentional here: title ingestion starts at a
/// synchronous runtime callback, and app policy forbids sleep-based debouncing.
///
/// SAFETY: `DispatchSourceTimer` supports concurrent cancellation, the source
/// is immutable after initialization, and the only captured callback is
/// `@Sendable`. The unchecked conformance hides the SDK's missing Sendable
/// annotation; it does not protect mutable Swift state.
final class GhosttyTitleUpdateDeadline: @unchecked Sendable {
    private let timer: any DispatchSourceTimer

    init(
        interval: Duration,
        action: @escaping @Sendable () async -> Void
    ) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        self.timer = timer
        timer.schedule(deadline: .now() + Self.dispatchInterval(for: interval))
        timer.setEventHandler {
            Task {
                await action()
            }
        }
        timer.resume()
    }

    func cancel() {
        timer.cancel()
    }

    deinit {
        cancel()
    }

    private static func dispatchInterval(for duration: Duration) -> DispatchTimeInterval {
        let components = max(duration, .zero).components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        let nanoseconds = min(
            (seconds * 1_000_000_000).rounded(.up),
            9_000_000_000_000_000_000
        )
        return .nanoseconds(Int(nanoseconds))
    }
}
