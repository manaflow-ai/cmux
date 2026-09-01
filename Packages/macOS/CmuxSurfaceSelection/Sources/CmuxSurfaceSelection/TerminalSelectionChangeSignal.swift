/// Broadcasts terminal selection changes without sharing an accessibility
/// notification iterator with other consumers.
public final class TerminalSelectionChangeSignal: Sendable {
    public let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    public nonisolated init() {
        let (events, continuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.events = events
        self.continuation = continuation
    }

    @discardableResult
    public nonisolated func request() -> Bool {
        switch continuation.yield(()) {
        case .enqueued:
            return true
        case .dropped, .terminated:
            return false
        @unknown default:
            return false
        }
    }

    public nonisolated func finish() {
        continuation.finish()
    }

    deinit {
        continuation.finish()
    }
}
