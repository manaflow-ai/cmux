/// Broadcasts terminal selection changes without sharing an accessibility
/// notification iterator with other consumers.
public final class TerminalSelectionChangeSignal: Sendable {
    /// An async stream that yields once for each accepted selection-change request.
    ///
    /// The stream buffers at most the newest pending signal so a slow consumer
    /// cannot accumulate an unbounded notification backlog.
    public let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    /// Creates a signal with a newest-value, single-element buffering policy.
    public nonisolated init() {
        let (events, continuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.events = events
        self.continuation = continuation
    }

    /// Requests delivery of one selection-change signal.
    ///
    /// Returns `true` when the stream accepts the request. Repeated requests
    /// can replace the buffered value and coalesce into one yielded signal;
    /// returns `false` after the stream has been finished.
    @discardableResult
    public nonisolated func request() -> Bool {
        switch continuation.yield(()) {
        case .enqueued:
            return true
        case .dropped:
            // bufferingNewest(1) drops the older value to accept this one.
            return true
        case .terminated:
            return false
        @unknown default:
            return false
        }
    }

    /// Finishes the stream and prevents subsequent requests from being delivered.
    public nonisolated func finish() {
        continuation.finish()
    }

    deinit {
        continuation.finish()
    }
}
