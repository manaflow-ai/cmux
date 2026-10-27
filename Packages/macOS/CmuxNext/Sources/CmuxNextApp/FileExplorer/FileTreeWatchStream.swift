import CmuxNextCompat
import CmuxNextWakeups
import CoreServices
import Foundation

/// The live FileTreeWatchStreams by the token each gives FSEvents as its context.
private nonisolated let fileTreeWatchCallbacks = CallbackRegistry<FileTreeWatchStream>(capacity: 256)

/// The FSEventStream behind one ``FileTreeWatcher`` stream. The stream's termination handler
/// (``FileTreeWatcher/changes(under:)``) owns it until `stop()` has run.
// FSEvents has no async API; the stream is created, scheduled, and stopped on `queue` (event
// delivery, not a lock), and its callback runs there too, so every mutation happens on `queue`.
// SAFETY: `stream` is the FSEventStreamRef this object created and alone releases (disarm()), so it is live
// whenever it is non-nil.
@safe nonisolated final class FileTreeWatchStream: @unchecked Sendable { // crash-allow: `stream`, `token`, `latency` and `stopped` change only on the serial `queue` (start, setLatency, stop, and the FSEvents callback there); the rest is immutable
    private let paths: [String]
    /// The coalescing latency of the running FSEvents stream; ``setLatency(_:)`` re-arms it with a new one.
    private var latency: CFTimeInterval
    private let started: (@Sendable (_ latency: CFTimeInterval) -> Void)?
    private let continuation: AsyncStream<Void>.Continuation
    /// The watch's record in the arm census (Debug and bench builds; nothing in Release).
    private let census: ArmCensusWatch
    private let queue = DispatchQueue(label: "cmux.files.tree-fsevents", qos: .utility)
    private var stream: FSEventStreamRef?
    private var token: CallbackToken?
    /// `stop()` ran: nothing arms the stream again.
    private var stopped = false

    init(paths: [String], latency: CFTimeInterval, started: (@Sendable (_ latency: CFTimeInterval) -> Void)?,
         census: ArmCensusWatch, continuation: AsyncStream<Void>.Continuation) {
        self.paths = paths
        self.latency = latency
        self.started = started
        self.census = census
        self.continuation = continuation
    }

    func start() {
        queue.async { [self] in
            guard !stopped else { return }
            arm()
        }
    }

    /// Coalesces with `latency` from now (Energy Saver turned on or off): a running stream is made again
    /// with it, and the stream yields once: a change the old stream still held, or one made between the two
    /// streams, reaches neither.
    func setLatency(_ latency: CFTimeInterval) {
        queue.async { [self] in
            guard latency != self.latency else { return }
            self.latency = latency
            // SAFETY: `stream` is only read for nil here.
            guard !stopped, unsafe stream != nil else { return }
            disarm()
            arm()
            continuation.yield()
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            disarm()
        }
    }

    /// Creates and starts the FSEvents stream with ``latency``; on `queue`.
    private func arm() {
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
        census.armed()
        started?(latency)
    }

    /// Stops and releases the running FSEvents stream, if any; on `queue`.
    private func disarm() {
        // SAFETY: `stream` is the live stream arm() created.
        guard let stream = unsafe stream else { return }
        unsafe FSEventStreamStop(stream)
        unsafe FSEventStreamInvalidate(stream)
        unsafe FSEventStreamRelease(stream)
        unsafe self.stream = nil
        // Invalidated on its own queue, the stream can no longer call back with the token.
        if let token { fileTreeWatchCallbacks.unregister(token) }
        token = nil
    }

    fileprivate func deliver(_ paths: [String]) {
        census.fired()
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
