import CmuxNextCompat
import CoreServices
import Foundation

/// The live FileTreeWatchStreams by the token each gives FSEvents as its context.
private nonisolated let fileTreeWatchCallbacks = CallbackRegistry<FileTreeWatchStream>(capacity: 256)

/// The FSEventStream behind one ``FileTreeWatcher`` stream. The stream's termination handler
/// (``FileTreeWatcher/changes(under:)``) owns it until `stop()` has run.
// FSEvents has no async API; the stream is created, scheduled, and stopped on `queue` (event
// delivery, not a lock), and its callback runs there too, so every mutation happens on `queue`.
// SAFETY: `stream` is the FSEventStreamRef this object created and alone releases (stop()), so it is live
// whenever it is non-nil.
@safe nonisolated final class FileTreeWatchStream: @unchecked Sendable { // crash-allow: `stream` and `token` change only on the serial `queue` (start, stop, and the FSEvents callback there); the rest is immutable
    private let paths: [String]
    private let latency: CFTimeInterval
    private let started: (@Sendable () -> Void)?
    private let continuation: AsyncStream<Void>.Continuation
    private let queue = DispatchQueue(label: "cmux.files.tree-fsevents", qos: .utility)
    private var stream: FSEventStreamRef?
    private var token: CallbackToken?

    init(paths: [String], latency: CFTimeInterval, started: (@Sendable () -> Void)?, continuation: AsyncStream<Void>.Continuation) {
        self.paths = paths
        self.latency = latency
        self.started = started
        self.continuation = continuation
    }

    func start() {
        queue.async { [self] in
            guard let token = try? fileTreeWatchCallbacks.register(self) else { continuation.finish(); return }
            // SAFETY: the context's `info` is a token, never dereferenced; FSEventStreamCreate copies the context
            // struct, a local live for the call.
            var context = unsafe FSEventStreamContext(version: 0, info: token.context,
                                                      retain: nil, release: nil, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
            guard let created = unsafe FSEventStreamCreate(nil, fileTreeWatchCallback, &context, paths as CFArray,
                                                           FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
            else {
                fileTreeWatchCallbacks.unregister(token)
                continuation.finish()
                return
            }
            unsafe stream = created
            self.token = token
            unsafe FSEventStreamSetDispatchQueue(created, queue)
            unsafe FSEventStreamStart(created)
            started?()
        }
    }

    func stop() {
        queue.async { [self] in
            // SAFETY: `stream` is the live stream start() created.
            guard let stream = unsafe stream else { return }
            unsafe FSEventStreamStop(stream)
            unsafe FSEventStreamInvalidate(stream)
            unsafe FSEventStreamRelease(stream)
            unsafe self.stream = nil
            // Invalidated on its own queue, the stream can no longer call back with the token.
            if let token { fileTreeWatchCallbacks.unregister(token) }
            token = nil
        }
    }

    fileprivate func deliver(_ paths: [String]) {
        guard paths.contains(where: FileTreeWatcher.counts) else { return }
        continuation.yield()
    }
}

nonisolated private func fileTreeWatchCallback(
    _ stream: ConstFSEventStreamRef, _ info: UnsafeMutableRawPointer?, _ count: Int,
    _ paths: UnsafeMutableRawPointer, _ flags: UnsafePointer<FSEventStreamEventFlags>,
    _ ids: UnsafePointer<FSEventStreamEventId>
) {
    // SAFETY: `info` is only read back as a token (one whose watcher stopped or went away is ignored and counted);
    // with kFSEventStreamCreateFlagUseCFTypes `paths` is a CFArray of CFStrings the stream owns for the callback.
    guard let watcher = unsafe fileTreeWatchCallbacks.target(forContext: info) else { return }
    watcher.deliver((unsafe Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String]) ?? [])
}
