import CoreServices
import Foundation

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
/// **Threading.** Every instance shares one serial dispatch queue (rather than
/// one queue per stream) to bound thread usage when many workspaces are tracked.
/// All mutable state is touched only on that queue, which is why the type is
/// `@unchecked Sendable`. ``onEvent`` fires on the shared queue, so it MUST be
/// non-blocking — a slow sink would serialize behind every other stream's
/// teardown. The production sink only spawns a `Task` and returns.
///
/// **Context lifetime.** The stream is registered with FSEvents as its own
/// context `info` pointer, passed *unretained* (no `retain`/`release` callbacks).
/// That is safe because ``stop()`` invalidates the stream synchronously on the
/// shared queue before `deinit` returns: FSEvents delivers callbacks on that
/// same serial queue, so any in-flight or already-enqueued callback runs to
/// completion before the `queue.sync` teardown block, and none is delivered
/// after `FSEventStreamInvalidate`. No callback ever touches a freed instance,
/// so a separately retained context box is unnecessary.
final class FileSystemEventStream: @unchecked Sendable {
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
    private static let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
        guard let info else { return }
        Unmanaged<FileSystemEventStream>.fromOpaque(info).takeUnretainedValue().onEvent()
    }

    /// The non-blocking sink invoked on the shared queue for each coalesced batch
    /// of filesystem events.
    private let onEvent: @Sendable () -> Void
    private var stream: FSEventStreamRef?

    /// Creates and starts a stream for `paths`.
    ///
    /// - Parameters:
    ///   - paths: The files and directories to watch. Must be non-empty.
    ///   - excludedPaths: Descendant paths ignored by the stream. Use this for
    ///     high-churn subtrees that should not wake downstream reloads.
    ///   - latency: The FSEvents coalescing latency in seconds.
    ///   - onEvent: A non-blocking sink invoked on the shared queue for each
    ///     coalesced batch of filesystem events.
    /// - Returns: `nil` if `paths` is empty or the underlying `FSEventStream`
    ///   could not be created or started.
    init?(
        paths: [String],
        excludedPaths: [String] = [],
        latency: TimeInterval,
        onEvent: @escaping @Sendable () -> Void
    ) {
        guard !paths.isEmpty else { return nil }
        self.onEvent = onEvent
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
            return nil
        }
        self.stream = stream
        if !excludedPaths.isEmpty {
            _ = FSEventStreamSetExclusionPaths(stream, excludedPaths as CFArray)
        }
        FSEventStreamSetDispatchQueue(stream, Self.queue)
        guard FSEventStreamStart(stream) else {
            stop()
            return nil
        }
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
