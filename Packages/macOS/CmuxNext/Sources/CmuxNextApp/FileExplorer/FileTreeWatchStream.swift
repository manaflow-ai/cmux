import CoreServices
import Foundation

/// The FSEventStream behind one ``FileTreeWatcher`` stream.
// FSEvents has no async API; the stream is created, scheduled, and stopped on `queue` (event
// delivery, not a lock), and its callback runs there too, so every mutation happens on `queue`.
nonisolated final class FileTreeWatchStream: @unchecked Sendable { // crash-allow: `stream` changes only on the serial `queue` (start, stop, and the FSEvents callback there); the rest is immutable
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
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
            guard let created = FSEventStreamCreate(nil, fileTreeWatchCallback, &context, paths as CFArray,
                                                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
            else { continuation.finish(); return }
            stream = created
            // Keeps self alive while the stream may call back; released in stop().
            _ = Unmanaged.passRetained(self)
            FSEventStreamSetDispatchQueue(created, queue)
            FSEventStreamStart(created)
            started?()
        }
    }

    func stop() {
        queue.async { [self] in
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            Unmanaged.passUnretained(self).release()
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
    guard let info else { return }
    let watcher = Unmanaged<FileTreeWatchStream>.fromOpaque(info).takeUnretainedValue()
    watcher.deliver((Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String]) ?? [])
}
