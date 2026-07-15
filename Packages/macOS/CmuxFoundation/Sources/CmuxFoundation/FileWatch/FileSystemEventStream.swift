import CoreServices
import Foundation

/// A stoppable source of raw filesystem-event identities.
///
/// `RecursivePathWatcher` owns this source and applies its coalescing policy to
/// ``events``. Keeping acquisition behind this small protocol separates the
/// FSEvents transport from the event pipeline without exposing either one's
/// mutable state.
protocol FileWatchEventSource: Sendable {
    var events: AsyncStream<FileWatchEventIdentity> { get }
    func stop()
}

/// A thin owner of an `FSEventStream` that reports raw filesystem events through
/// an `AsyncStream`.
///
/// `FSEventStream` is a C API with no async-native replacement, and it is the
/// only macOS primitive that watches a *set of paths recursively* with a single
/// coalescing stream (a `DispatchSource` file source watches one descriptor and
/// does not recurse). It stays hidden behind this type; consumers
/// (``RecursivePathWatcher``) observe events only via the watcher's
/// `AsyncStream`. The stream is configured for file-level events.
///
/// **Threading.** Every instance shares one serial dispatch queue (rather than
/// one queue per stream) to bound thread usage when many workspaces are tracked.
/// All mutable state is touched only on that queue, which is why the type is
/// `@unchecked Sendable`. The callback only yields into ``events``, so it never
/// blocks the shared queue behind a consumer's work.
///
/// **Context lifetime.** The stream is registered with FSEvents as its own
/// context `info` pointer, passed *unretained* (no `retain`/`release` callbacks).
/// That is safe because ``stop()`` invalidates the stream synchronously on the
/// shared queue before `deinit` returns: FSEvents delivers callbacks on that
/// same serial queue, so any in-flight or already-enqueued callback runs to
/// completion before the `queue.sync` teardown block, and none is delivered
/// after `FSEventStreamInvalidate`. No callback ever touches a freed instance,
/// so a separately retained context box is unnecessary.
final class FileSystemEventStream: FileWatchEventSource, @unchecked Sendable {
    private static let queueSpecificKey = DispatchSpecificKey<UInt8>()
    private static let queue: DispatchQueue = {
        let queue = DispatchQueue(label: "com.cmux.recursive-path-watcher", qos: .utility)
        queue.setSpecific(key: queueSpecificKey, value: 1)
        return queue
    }()

    /// The C trampoline `FSEventStreamCreate` requires.
    ///
    /// It must be a context-free `@convention(c)` function pointer, so it cannot
    /// be an instance method (which would be curried over `self`). The owning
    /// stream is recovered from the context's `info` pointer instead — passed
    /// *unretained* (see the type's "Context lifetime" note), so this uses
    /// `takeUnretainedValue()` and never adjusts the reference count.
    private static let callback: FSEventStreamCallback = {
        _, info, eventCount, _, eventFlags, eventIDs in
        guard let info, eventCount > 0 else { return }
        var latestEventID = eventIDs[0]
        var combinedFlags: FSEventStreamEventFlags = 0
        for index in 0..<eventCount {
            latestEventID = max(latestEventID, eventIDs[index])
            combinedFlags |= eventFlags[index]
        }
        Unmanaged<FileSystemEventStream>
            .fromOpaque(info)
            .takeUnretainedValue()
            .continuation.yield(eventIdentity(
                latestEventID: latestEventID,
                flags: combinedFlags
            ))
    }

    let events: AsyncStream<FileWatchEventIdentity>
    private let continuation: AsyncStream<FileWatchEventIdentity>.Continuation
    private var stream: FSEventStreamRef?

    /// Creates and starts a stream for `paths`.
    ///
    /// - Parameters:
    ///   - paths: The files and directories to watch. Must be non-empty.
    ///   - latency: The FSEvents coalescing latency in seconds.
    /// - Returns: `nil` if `paths` is empty or the underlying `FSEventStream`
    ///   could not be created or started.
    init?(
        paths: [String],
        latency: TimeInterval
    ) {
        guard !paths.isEmpty else { return nil }
        (self.events, self.continuation) = AsyncStream<FileWatchEventIdentity>.makeStream()
        self.stream = nil

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(
            nil,
            Self.callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            continuation.finish()
            return nil
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, Self.queue)
        guard FSEventStreamStart(stream) else {
            stop()
            return nil
        }
    }

    static func eventIdentity(
        latestEventID: FSEventStreamEventId,
        flags: FSEventStreamEventFlags
    ) -> FileWatchEventIdentity {
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped) != 0 {
            return .eventIDsWrapped
        }
        let conservativeFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
        if flags & conservativeFlags != 0 {
            return .mustRescan
        }
        return .stable(FileWatchEventID(rawValue: latestEventID))
    }

    /// Stops and tears down the stream. Idempotent.
    ///
    /// Teardown runs synchronously on the shared queue so it completes before the
    /// caller continues — critically, before `deinit` returns. An async hop could
    /// let the instance deallocate before the stream is invalidated, leaking the
    /// `FSEventStream`. The `getSpecific` check tears down inline when already on
    /// the queue, avoiding a deadlock.
    func stop() {
        if DispatchQueue.getSpecific(key: Self.queueSpecificKey) != nil {
            stopOnQueue()
        } else {
            Self.queue.sync { stopOnQueue() }
        }
        continuation.finish()
    }

    private func stopOnQueue() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}
