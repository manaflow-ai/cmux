import CoreServices
public import Foundation

/// Watches folders with FSEvents and yields what changed under them, file by
/// file. No polling: the stream wakes only when the file system reports a
/// change, coalesced over ``latency``.
///
/// ```swift
/// for await batch in DirectoryWatcher().events(for: ["/Users/me/Desktop"]) {
///     // batch: [DirectoryWatcherEvent]
/// }
/// ```
///
/// Ending the iteration (or cancelling its task) stops and releases the
/// FSEvents stream.
public nonisolated struct DirectoryWatcher: DirectoryWatching {
    /// Seconds FSEvents coalesces changes for. The first change after a quiet
    /// period is delivered at once (`kFSEventStreamCreateFlagNoDefer`), so a
    /// new screenshot shows without this delay.
    public var latency: TimeInterval

    /// Makes a watcher.
    ///
    /// - Parameter latency: coalescing window in seconds (default 0.15).
    public init(latency: TimeInterval = 0.15) {
        self.latency = latency
    }

    /// The changes under `paths`, one batch per FSEvents callback. An empty
    /// `paths` yields nothing and finishes at once.
    ///
    /// - Parameter paths: folders to watch (recursively, as FSEvents does).
    /// - Returns: a stream of change batches.
    public func events(for paths: [String]) -> AsyncStream<[DirectoryWatcherEvent]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [DirectoryWatcherEvent].self, bufferingPolicy: .bufferingNewest(64))
        guard !paths.isEmpty else {
            continuation.finish()
            return stream
        }
        let sink = DirectoryWatcherSink(continuation: continuation)
        let info = Unmanaged.passRetained(sink).toOpaque()
        var context = FSEventStreamContext(version: 0, info: info, retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let ref = FSEventStreamCreate(kCFAllocatorDefault, DirectoryWatcherSink.callback, &context, paths as CFArray,
                                            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
            Unmanaged<DirectoryWatcherSink>.fromOpaque(info).release()
            continuation.finish()
            return stream
        }
        // Event delivery only (allowed carve-out): FSEvents calls back on this queue; no state is guarded by it.
        let queue = DispatchQueue(label: "cmux.filegrid.fsevents", qos: .utility)
        let handle = DirectoryWatcherStreamHandle(ref: ref, info: info)
        FSEventStreamSetDispatchQueue(ref, queue)
        FSEventStreamStart(ref)
        continuation.onTermination = { _ in
            queue.async { handle.stop() }
        }
        return stream
    }
}
