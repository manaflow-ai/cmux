import CmuxNextCompat
import CoreServices
import Foundation

/// The live FolderWatchStreams by the token each gives FSEvents as its context.
private let folderWatchCallbacks = CallbackRegistry<FolderWatchStream>(capacity: 1024)

/// The FSEventStream behind one ``FolderWatcher`` stream. The stream's termination handler
/// (``FolderWatcher/changes(in:)``) owns it until `stop()` has run.
// FSEvents has no async API; the stream is created, scheduled, and stopped on
// `queue`, and its callback runs there too, so every mutation happens on `queue`.
final class FolderWatchStream: @unchecked Sendable { // crash-allow: `stream` and `token` change only on the serial `queue` (start, stop, and the FSEvents callback there); the rest is immutable
    private let folderPath: String
    private let latency: CFTimeInterval
    private let continuation: AsyncStream<FolderChange>.Continuation
    private let queue = DispatchQueue(label: "cmux.files.fsevents", qos: .userInitiated)
    private var stream: FSEventStreamRef?
    private var token: CallbackToken?

    init(folder: URL, latency: CFTimeInterval, continuation: AsyncStream<FolderChange>.Continuation) {
        self.folderPath = folder.path.hasSuffix("/") ? String(folder.path.dropLast()) : folder.path
        self.latency = latency
        self.continuation = continuation
    }

    func start() {
        queue.async { [self] in
            guard let token = try? folderWatchCallbacks.register(self) else { continuation.finish(); return }
            // SAFETY: FSEventStreamCreate copies the context, a local live for the call; its `info` is a token.
            var context = unsafe FSEventStreamContext(version: 0, info: token.context,
                                                      retain: nil, release: nil, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)
            guard let created = unsafe FSEventStreamCreate(nil, folderWatchCallback, &context, [folderPath] as CFArray,
                                                           FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
            else {
                folderWatchCallbacks.unregister(token)
                continuation.finish()
                return
            }
            stream = created
            self.token = token
            FSEventStreamSetDispatchQueue(created, queue)
            FSEventStreamStart(created)
        }
    }

    func stop() {
        queue.async { [self] in
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            // Invalidated on its own queue, the stream can no longer call back with the token.
            if let token { folderWatchCallbacks.unregister(token) }
            token = nil
        }
    }

    fileprivate func deliver(paths: [String], flags: [FSEventStreamEventFlags]) {
        var items: [String] = []
        var rescan = false
        for (path, flag) in zip(paths, flags) {
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
                | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0 {
                rescan = true
                continue
            }
            let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
            if trimmed == folderPath { continue }
            let parent = (trimmed as NSString).deletingLastPathComponent
            guard parent == folderPath else { continue }
            items.append((trimmed as NSString).lastPathComponent)
        }
        guard rescan || !items.isEmpty else { return }
        // A full buffer drops its oldest change; the rescan after it covers whatever was lost.
        if case .dropped = continuation.yield(rescan ? .rescan : .items(items)) { continuation.yield(.rescan) }
    }
}

private func folderWatchCallback(
    _ stream: ConstFSEventStreamRef, _ info: UnsafeMutableRawPointer?, _ count: Int,
    _ paths: UnsafeMutableRawPointer, _ flags: UnsafePointer<FSEventStreamEventFlags>,
    _ ids: UnsafePointer<FSEventStreamEventId>
) {
    // A token whose watcher stopped or went away is ignored (and counted by the registry).
    guard let watcher = unsafe folderWatchCallbacks.target(forContext: info) else { return }
    let list = (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String]) ?? []
    watcher.deliver(paths: list, flags: Array(UnsafeBufferPointer(start: flags, count: count)))
}
