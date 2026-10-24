public import CmuxNextErrorJournal

/// An ``ErrorRecording`` that hands each recorded event to ``events``, for a test that checks
/// what a page or pane reported.
public nonisolated final class RecordedErrors: ErrorRecording {
    /// Every event, in the order recorded.
    public let events: AsyncStream<ErrorEvent>
    private let continuation: AsyncStream<ErrorEvent>.Continuation

    /// Makes an empty recorder.
    public init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    /// Hands `event` to ``events``.
    public func record(_ event: ErrorEvent) async {
        continuation.yield(event)
    }
}
