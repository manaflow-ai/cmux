import CoreServices
import Foundation

/// One raw callback batch from FSEvents.
struct FileSystemEventBatch: Sendable {
    let paths: [String]
    let requiresFullRescan: Bool
}

/// A thin owner of an `FSEventStream` that reports raw filesystem events through
/// a `@Sendable` sink.
///
/// `FSEventStream` is a C API with no async-native replacement, and it is the
/// only macOS primitive that watches a *set of paths recursively* with a single
/// coalescing stream (a `DispatchSource` file source watches one descriptor and
/// does not recurse). It stays hidden behind this type; consumers
/// (``RecursivePathWatcher``) observe events only via the watcher's
/// `AsyncStream`. The stream is configured for file-level events.
///
/// Native registration and teardown run on a dedicated serial I/O queue. The
/// callback context is independently retained by FSEvents, so deallocation can
/// enqueue teardown without waiting for a daemon call or an in-flight callback.
///
/// The native pointer is immutable after construction; it crosses the queue
/// only for its single ownership transfer into teardown. All native lifecycle
/// calls and callbacks execute on that queue.
final class FileSystemEventStream: @unchecked Sendable {
    private static let queue = DispatchQueue(
        label: "com.cmux.recursive-path-watcher", qos: .utility
    )

    /// The C trampoline `FSEventStreamCreate` requires.
    ///
    /// It must be a context-free `@convention(c)` function pointer, so it cannot
    /// be an instance method (which would be curried over `self`). The owning
    /// callback receiver is recovered from the context retained by FSEvents.
    private static let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, eventFlags, _ in
        guard let info else { return }
        let owner = Unmanaged<FileSystemEventReceiver>.fromOpaque(info).takeUnretainedValue()
        owner.onEvent(FileSystemEventBatch(
            paths: paths(from: eventPaths, count: min(eventCount, maximumPathsPerBatch)),
            requiresFullRescan: eventCount > maximumPathsPerBatch
                || flagsRequireFullRescan(eventFlags, count: eventCount)
        ))
    }

    private let stream: FSEventStreamRef
    private let lifecycleQueue: DispatchQueue

    /// Bounds native-to-Swift path copying for a single callback. A larger batch
    /// is represented as a full-rescan marker instead of allocating without limit.
    private static let maximumPathsPerBatch = 4_096

    private static let fullRescanFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagEventIdsWrapped
            | kFSEventStreamEventFlagRootChanged
            | kFSEventStreamEventFlagMount
            | kFSEventStreamEventFlagUnmount
    )

    private static func paths(from eventPaths: UnsafeMutableRawPointer, count: Int) -> [String] {
        guard count > 0 else { return [] }
        let rawPaths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
        var paths: [String] = []
        paths.reserveCapacity(count)
        for index in 0..<count {
            paths.append(String(cString: rawPaths[index]))
        }
        return paths
    }

    private static func flagsRequireFullRescan(
        _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
        count: Int
    ) -> Bool {
        for index in 0..<count where eventFlags[index] & fullRescanFlags != 0 {
            return true
        }
        return false
    }

    /// Suspends while the native stream registers on the blocking-I/O lane.
    static func start(
        paths: [String],
        latency: TimeInterval,
        onEvent: @escaping @Sendable (FileSystemEventBatch) -> Void,
        queue: DispatchQueue = FileSystemEventStream.queue
    ) async -> FileSystemEventStream? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: FileSystemEventStream(
                    paths: paths, latency: latency, onEvent: onEvent, queue: queue
                ))
            }
        }
    }

    private init?(
        paths: [String],
        latency: TimeInterval,
        onEvent: @escaping @Sendable (FileSystemEventBatch) -> Void,
        queue: DispatchQueue
    ) {
        guard !paths.isEmpty else { return nil }
        let receiver = FileSystemEventReceiver(onEvent: onEvent)
        var context = receiver.makeContext()
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        let createdStream = withExtendedLifetime(receiver) {
            FSEventStreamCreate(
                nil,
                Self.callback,
                &context,
                paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                flags
            )
        }
        guard let stream = createdStream else { return nil }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
        self.lifecycleQueue = queue
    }

    deinit {
        // The C pointer's only remaining owner is this queued cleanup. Its
        // retained receiver stays alive until FSEventStreamRelease runs.
        nonisolated(unsafe) let retiredStream = stream
        lifecycleQueue.async {
            FSEventStreamStop(retiredStream)
            FSEventStreamInvalidate(retiredStream)
            FSEventStreamRelease(retiredStream)
        }
    }
}
