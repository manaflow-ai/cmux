#if canImport(CoreServices)
import CmuxNextCompat
import CoreServices
import Foundation

/// The live FolderWatchStreams by the token each gives FSEvents as its context.
private let folderWatchCallbacks = CallbackRegistry<FolderWatchStream>(capacity: 1024)

/// The FSEventStream behind one ``FolderWatcher`` stream. The stream's termination handler
/// (``FolderWatcher/changes(in:)``) owns it until `stop()` has run.
// FSEvents has no async API; the stream is created, scheduled, and stopped on
// `queue`, and its callback runs there too, so every mutation happens on `queue`.
// SAFETY: `stream` is the FSEventStreamRef this object created and alone releases (stop()), so it is live
// whenever it is non-nil.
@safe final class FolderWatchStream: @unchecked Sendable { // crash-allow: `stream` and `token` change only on the serial `queue` (start, stop, and the FSEvents callback there); the rest is immutable
    private let folderPath: String
    private let latency: TimeInterval
    private let continuation: AsyncStream<FolderChange>.Continuation
    private let queue = DispatchQueue(label: "cmux.files.fsevents", qos: .userInitiated)
    private var stream: FSEventStreamRef?
    private var token: CallbackToken?

    init(folder: URL, latency: TimeInterval, continuation: AsyncStream<FolderChange>.Continuation) {
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
            unsafe stream = created
            self.token = token
            unsafe FSEventStreamSetDispatchQueue(created, queue)
            unsafe FSEventStreamStart(created)
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
    // SAFETY: `info` is only read back as a token (one whose watcher stopped or went away is ignored and counted);
    // with kFSEventStreamCreateFlagUseCFTypes `paths` is a CFArray of CFStrings the stream owns for the callback, and
    // `flags` holds `count` event flags, copied into an array before the callback returns.
    guard let watcher = unsafe folderWatchCallbacks.target(forContext: info) else { return }
    let list = unsafe (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String]) ?? []
    watcher.deliver(paths: list, flags: unsafe Array(UnsafeBufferPointer(start: flags, count: count)))
}
#endif
