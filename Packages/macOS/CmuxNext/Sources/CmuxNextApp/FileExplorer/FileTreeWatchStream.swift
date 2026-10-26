import CoreServices
import Foundation

/// The FSEventStream behind one ``FileTreeWatcher`` stream.
// FSEvents has no async API; the stream is created, scheduled, and stopped on `queue` (event
// delivery, not a lock), and its callback runs there too, so every mutation happens on `queue`.
// SAFETY: `stream` is the FSEventStreamRef this object created and alone releases (stop()), so it is live
// whenever it is non-nil.
@safe nonisolated final class FileTreeWatchStream: @unchecked Sendable { // crash-allow: `stream` changes only on the serial `queue` (start, stop, and the FSEvents callback there); the rest is immutable
    private let paths: [String]
    private let latency: CFTimeInterval
    private let started: (@Sendable () -> Void)?
    private let continuation: AsyncStream<Void>.Continuation
    private let queue = DispatchQueue(label: "cmux.files.tree-fsevents", qos: .utility)
    private var stream: FSEventStreamRef?

    init(paths: [String], latency: CFTimeInterval, started: (@Sendable () -> Void)?, continuation: AsyncStream<Void>.Continuation) {
        self.paths = paths
        self.latency = latency
        self.started = started
        self.continuation = continuation
    }

    func start() {
        queue.async { [self] in
            // SAFETY: the context's `info` is this object, retained once below before the stream can call back
            // and released only in stop() after the stream is invalidated, so the callback's info is always live;
            // FSEventStreamCreate copies the context struct, a local live for the call.
            var context = unsafe FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                                      retain: nil, release: nil, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
            guard let created = unsafe FSEventStreamCreate(nil, fileTreeWatchCallback, &context, paths as CFArray,
                                                           FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
            else { continuation.finish(); return }
            unsafe stream = created
            // Keeps self alive while the stream may call back; released in stop().
            _ = unsafe Unmanaged.passRetained(self)
            unsafe FSEventStreamSetDispatchQueue(created, queue)
            unsafe FSEventStreamStart(created)
            started?()
        }
    }

    func stop() {
        queue.async { [self] in
            // SAFETY: `stream` is the live stream start() created; after FSEventStreamInvalidate on its own queue
            // no callback can run, so the retain start() took on self is released last.
            guard let stream = unsafe stream else { return }
            unsafe FSEventStreamStop(stream)
            unsafe FSEventStreamInvalidate(stream)
            unsafe FSEventStreamRelease(stream)
            unsafe self.stream = nil
            unsafe Unmanaged.passUnretained(self).release()
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
    // SAFETY: `info` is the FileTreeWatchStream start() retained, live until stop() (see there); with
    // kFSEventStreamCreateFlagUseCFTypes `paths` is a CFArray of CFStrings the stream owns for the callback.
    guard let info = unsafe info else { return }
    let watcher = unsafe Unmanaged<FileTreeWatchStream>.fromOpaque(info).takeUnretainedValue()
    watcher.deliver((unsafe Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String]) ?? [])
}
