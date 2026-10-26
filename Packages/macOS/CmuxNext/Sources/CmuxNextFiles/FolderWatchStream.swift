import CoreServices
import Foundation

/// The FSEventStream behind one ``FolderWatcher`` stream.
// FSEvents has no async API; the stream is created, scheduled, and stopped on
// `queue`, and its callback runs there too, so every mutation happens on `queue`.
// SAFETY: `stream` is the FSEventStreamRef this object created and alone releases (stop()), so it is live
// whenever it is non-nil.
@safe final class FolderWatchStream: @unchecked Sendable { // crash-allow: `stream` changes only on the serial `queue` (start, stop, and the FSEvents callback there); the rest is immutable
    private let folderPath: String
    private let latency: CFTimeInterval
    private let continuation: AsyncStream<FolderChange>.Continuation
    private let queue = DispatchQueue(label: "cmux.files.fsevents", qos: .userInitiated)
    private var stream: FSEventStreamRef?

    init(folder: URL, latency: CFTimeInterval, continuation: AsyncStream<FolderChange>.Continuation) {
        self.folderPath = folder.path.hasSuffix("/") ? String(folder.path.dropLast()) : folder.path
        self.latency = latency
        self.continuation = continuation
    }

    func start() {
        queue.async { [self] in
            // SAFETY: the context's `info` is this object, retained once below before the stream can call back
            // and released only in stop() after the stream is invalidated, so the callback's info is always live;
            // FSEventStreamCreate copies the context struct, a local live for the call.
            var context = unsafe FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                                      retain: nil, release: nil, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)
            guard let created = unsafe FSEventStreamCreate(nil, folderWatchCallback, &context, [folderPath] as CFArray,
                                                           FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
            else { continuation.finish(); return }
            unsafe stream = created
            // Keeps self alive while the stream may call back; released in stop().
            _ = unsafe Unmanaged.passRetained(self)
            unsafe FSEventStreamSetDispatchQueue(created, queue)
            unsafe FSEventStreamStart(created)
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
    // SAFETY: `info` is the FolderWatchStream start() retained, live until stop() (see there); with
    // kFSEventStreamCreateFlagUseCFTypes `paths` is a CFArray of CFStrings the stream owns for the callback, and
    // `flags` holds `count` event flags, copied into an array before the callback returns.
    guard let info = unsafe info else { return }
    let watcher = unsafe Unmanaged<FolderWatchStream>.fromOpaque(info).takeUnretainedValue()
    let list = unsafe (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String]) ?? []
    watcher.deliver(paths: list, flags: unsafe Array(UnsafeBufferPointer(start: flags, count: count)))
}
