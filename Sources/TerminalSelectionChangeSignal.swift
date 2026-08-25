import Foundation

/// Broadcasts Ghostty selection changes independently from the accessibility
/// notification stream, so a reactive event consumer cannot steal values from
/// the accessibility notifier's iterator.
final class TerminalSelectionChangeSignal: Sendable {
    let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    nonisolated init() {
        let (events, continuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.events = events
        self.continuation = continuation
    }

    @discardableResult
    nonisolated func request() -> Bool {
        switch continuation.yield(()) {
        case .enqueued:
            return true
        case .dropped, .terminated:
            return false
        @unknown default:
            return false
        }
    }

    nonisolated func finish() {
        continuation.finish()
    }

    deinit {
        continuation.finish()
    }
}
