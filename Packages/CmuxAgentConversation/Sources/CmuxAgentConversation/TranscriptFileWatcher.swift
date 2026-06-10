import Foundation

/// Watches one transcript file for filesystem changes, surfacing them as an
/// `AsyncStream` of empty signals.
///
/// Each call to ``TranscriptFileWatcher/changes()`` creates an independent
/// kqueue-backed subscription (via ``TranscriptWatchAttachment``) that follows
/// the file across truncation, deletion, and rotation. Consumers re-read the
/// file on every signal and diff, so signals carry no payload; kqueue's event
/// coalescing naturally bounds the signal (and therefore re-read) rate.
///
/// ```swift
/// let watcher = TranscriptFileWatcher(url: transcriptURL)
/// for await _ in watcher.changes() {
///     // re-read and diff the transcript
/// }
/// ```
struct TranscriptFileWatcher: Sendable {
    /// The transcript file path to watch.
    private let path: String

    /// Creates a watcher for the file at `url`.
    ///
    /// - Parameter url: The transcript file. It does not need to exist yet;
    ///   the watcher waits on the parent directory until it appears.
    init(url: URL) {
        self.path = url.path
    }

    /// Returns a fresh stream of change signals for the watched file.
    ///
    /// The stream finishes when the consumer's task is cancelled (terminating
    /// the stream stops the underlying kqueue sources and closes their
    /// descriptors).
    ///
    /// - Returns: A stream yielding `()` once per observed filesystem change.
    ///   Signals carry no payload and only the latest file state matters, so
    ///   the buffer keeps at most one pending signal: a burst of events that
    ///   lands while the consumer is mid-re-read coalesces into a single
    ///   follow-up re-read instead of queueing redundant full parses.
    func changes() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let attachment = TranscriptWatchAttachment(path: path, continuation: continuation)
            attachment.start()
            continuation.onTermination = { _ in attachment.stop() }
        }
    }
}
