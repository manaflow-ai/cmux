import CoreServices
import Darwin
import Foundation

/// Delivers FSEvents for one local root as ``FileTreeChangeBatch`` values.
///
/// FSEvents reports directories, coalesces over ``latency`` in the kernel and
/// covers the whole subtree with one stream, unlike a `DispatchSource` per
/// directory. Event paths arrive canonicalized (`/private/tmp`, resolved
/// symlinks); the stream maps them back under the root the tree displays.
struct FileSystemEventStream: Sendable {
    /// The displayed root.
    let rootPath: String
    /// The kernel coalescing window in seconds.
    let latency: TimeInterval

    /// Creates a stream description.
    /// - Parameters:
    ///   - rootPath: The absolute root the tree displays.
    ///   - latency: FSEvents coalescing in seconds. A build writing thousands of
    ///     files becomes a few batches per second.
    init(rootPath: String, latency: TimeInterval = 0.25) {
        self.rootPath = rootPath
        self.latency = latency
    }

    /// Starts FSEvents and returns its batches. Cancelling or dropping the
    /// consumer stops and releases the stream.
    func makeStream() -> AsyncStream<FileTreeChangeBatch> {
        let (stream, continuation) = AsyncStream<FileTreeChangeBatch>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        let displayRoot = Self.trimmedDirectory(rootPath)
        let canonicalRoot = Self.canonicalPath(displayRoot)
        let box = FileSystemEventStreamBox(
            continuation: continuation,
            displayRoot: displayRoot,
            canonicalRoot: canonicalRoot
        )
        // FSEvents needs a serial dispatch queue for delivery; it is the event
        // source, not a lock around shared state (concurrency carve-out).
        let queue = DispatchQueue(label: "cmux.file-tree.fsevents", qos: .utility)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(box).toOpaque(),
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<FileSystemEventStreamBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer
        )
        guard let eventStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            FileSystemEventStreamBox.callback,
            &context,
            [canonicalRoot] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            // FSEventStreamCreate copied nothing; balance the retain above.
            Unmanaged<FileSystemEventStreamBox>.fromOpaque(context.info!).release()
            continuation.finish()
            return stream
        }
        let handle = FileSystemEventStreamHandle(stream: eventStream, queue: queue)
        FSEventStreamSetDispatchQueue(eventStream, queue)
        FSEventStreamStart(eventStream)
        continuation.onTermination = { _ in
            handle.stop()
        }
        return stream
    }

    static func trimmedDirectory(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Owns the FSEvents stream reference so termination can stop it on its queue.
private final class FileSystemEventStreamHandle: @unchecked Sendable {
    // Accessed only on `queue` after creation; the reference is immutable.
    private let stream: FSEventStreamRef
    private let queue: DispatchQueue

    init(stream: FSEventStreamRef, queue: DispatchQueue) {
        self.stream = stream
        self.queue = queue
    }

    func stop() {
        let stream = self.stream
        queue.async {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

/// Context object handed to the C callback.
private final class FileSystemEventStreamBox: Sendable {
    let continuation: AsyncStream<FileTreeChangeBatch>.Continuation
    let displayRoot: String
    let canonicalRoot: String

    init(continuation: AsyncStream<FileTreeChangeBatch>.Continuation, displayRoot: String, canonicalRoot: String) {
        self.continuation = continuation
        self.displayRoot = displayRoot
        self.canonicalRoot = canonicalRoot
    }

    /// FSEvents' C callback; a `@convention(c)` trampoline is the one place a
    /// free function is required, so it lives here as a static closure.
    static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let box = Unmanaged<FileSystemEventStreamBox>.fromOpaque(info).takeUnretainedValue()
        let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
        var batch = FileTreeChangeBatch()
        for index in 0..<count {
            guard let rawPath = array[index] as? String else { continue }
            let path = box.displayPath(forCanonical: FileSystemEventStream.trimmedDirectory(rawPath))
            let eventFlags = Int(flags[index])
            if eventFlags & kFSEventStreamEventFlagRootChanged != 0 {
                batch.subtrees.insert(box.displayRoot)
            } else if eventFlags & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagKernelDropped |
                kFSEventStreamEventFlagUserDropped) != 0 {
                batch.subtrees.insert(path)
            } else {
                batch.directories.insert(path)
            }
        }
        if !batch.isEmpty {
            box.continuation.yield(batch)
        }
    }

    func displayPath(forCanonical path: String) -> String {
        if path == canonicalRoot { return displayRoot }
        let prefix = canonicalRoot == "/" ? "/" : canonicalRoot + "/"
        guard path.hasPrefix(prefix) else { return path }
        let suffix = path.dropFirst(prefix.count)
        return displayRoot == "/" ? "/" + suffix : displayRoot + "/" + suffix
    }
}
