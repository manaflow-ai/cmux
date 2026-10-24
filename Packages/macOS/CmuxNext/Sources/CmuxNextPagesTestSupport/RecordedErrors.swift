public import CmuxNextErrorJournal

/// An ``ErrorRecording`` that hands each recorded event to ``events``, for a test that checks
/// what a page or pane reported.
public nonisolated final class RecordedErrors: ErrorRecording {
    /// Events kept until the test reads them: one second of a page's reports (the
    /// ``ConsoleErrorCapture/script`` sends at most 20 a second). A test checks the first events
    /// it caused, so the stream keeps the oldest and drops any later ones past this many unread.
    public static let capacity = 20

    /// Every event, in the order recorded, up to ``capacity`` unread.
    public let events: AsyncStream<ErrorEvent>
    private let continuation: AsyncStream<ErrorEvent>.Continuation

    /// Makes an empty recorder.
    public init() {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(Self.capacity))
    }

    /// Hands `event` to ``events``.
    public func record(_ event: ErrorEvent) async {
        continuation.yield(event)
    }
}
