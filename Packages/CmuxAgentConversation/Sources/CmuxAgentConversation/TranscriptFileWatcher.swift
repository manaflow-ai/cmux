import Foundation

/// Watches one transcript file for filesystem changes, surfacing them as an
/// `AsyncStream` of empty signals.
///
/// Each call to ``TranscriptFileWatcher/withChanges(_:)`` creates an
/// independent kqueue-backed subscription (via ``TranscriptWatchAttachment``)
/// that follows the file across truncation, deletion, and rotation for the
/// duration of the passed closure. Consumers re-read the file on every signal
/// and diff, so signals carry no payload; kqueue's event coalescing naturally
/// bounds the signal (and therefore re-read) rate.
///
/// ```swift
/// await TranscriptFileWatcher(url: transcriptURL).withChanges { changes in
///     for await _ in changes {
///         // re-read and diff the transcript
///     }
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

    /// Runs `body` with a live stream of change signals for the watched file,
    /// tearing the watch down when `body` returns (including on cancellation).
    ///
    /// Structured ownership: the kqueue attachment lives exactly as long as
    /// `body`, so there is no continuation/attachment reference cycle and the
    /// dispatch sources and descriptors are always released when the consumer
    /// is done. If the consuming task is cancelled, the stream's iteration
    /// ends (`next()` returns `nil`), `body` returns, and teardown runs.
    ///
    /// The stream's first signal is a readiness handshake, yielded once the
    /// watch is installed: consumers should perform their initial read only
    /// after receiving it, so no write can land between the read and the
    /// attach. Signals carry no payload and only the latest file state
    /// matters, so the buffer keeps at most one pending signal: a burst of
    /// events that lands while the consumer is mid-re-read coalesces into a
    /// single follow-up re-read instead of queueing redundant full parses.
    ///
    /// - Parameter body: The consumer of the change-signal stream.
    /// - Returns: Whatever `body` returns.
    func withChanges<Result: Sendable>(
        _ body: (AsyncStream<Void>) async -> Result
    ) async -> Result {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let attachment = TranscriptWatchAttachment(path: path, continuation: continuation)
        attachment.start()
        defer { attachment.stop() }
        return await body(stream)
    }
}
