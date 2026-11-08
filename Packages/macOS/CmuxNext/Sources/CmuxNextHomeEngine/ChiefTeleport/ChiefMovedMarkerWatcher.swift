public import Foundation

/// Wakes when a Chief home's moved marker (`state/moved.json`) may have changed: a move wrote it, a
/// rollback removed it. A file-system watch on the home's `state` folder (the home itself until it
/// has one, its parent until the home exists), never polling; read the marker again on each wake
/// (``ChiefLocationReader``).
///
/// ```swift
/// for await _ in ChiefMovedMarkerWatcher(home: home).changes() { await model.refresh().value }
/// ```
public nonisolated struct ChiefMovedMarkerWatcher: Sendable {
    /// The Chief home followed.
    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    /// One wake per change (several changes between two reads come as one); the watch stops when
    /// the stream's consumer goes away.
    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let attachment = ChiefMovedMarkerAttachment(home: home, continuation: continuation)
        continuation.onTermination = { _ in attachment.cancel() }
        attachment.start()
        return stream
    }
}
