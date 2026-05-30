import Foundation

/// Watches a single file for change events and exposes them as an
/// `AsyncStream<Void>`.
///
/// Wraps `DispatchSource.makeFileSystemObjectSource` — the kqueue-backed
/// Foundation primitive for file events on macOS — because there is no
/// async-native replacement. The dispatch sources are owned by this actor
/// and stay isolated to it. Consumers see only the actor's ``events``
/// stream; `DispatchSource` itself is never exposed.
///
/// Construct one per file you want to watch and inject it into the
/// consumer (e.g. ``JSONConfigStore``). The watcher also observes the
/// parent directory so its stream recovers when the file is created or
/// replaced after the watcher starts — the standard cmux config file
/// frequently does not exist on first launch.
///
/// **Known race window.** ``init(fileURL:)`` schedules `Task { await
/// self.start() }` to attach the dispatch sources on the actor's
/// executor. Between init returning and that Task running, kqueue is not
/// yet listening, so file events in that window are missed. The window
/// is short (one actor-executor hop) and pragmatic for now; a future
/// revisit may move construction to an `async make()` factory so source
/// arming completes before the caller gets a watcher back.
///
/// ```swift
/// let watcher = JSONConfigFileWatcher(fileURL: locations.userConfigFile)
/// for await _ in watcher.events {
///     await store.reloadFromDisk()
/// }
/// ```
public actor JSONConfigFileWatcher {
    /// Stream of change events. Yields one element per file-system event
    /// affecting the watched file or its parent directory.
    public nonisolated let events: AsyncStream<Void>

    private let fileURL: URL
    // DispatchSource.makeFileSystemObjectSource requires a DispatchQueue.
    // No async-native Foundation API exists for kqueue file events; this
    // queue is internal isolation only and never exposed.
    private let queue: DispatchQueue
    private let continuation: AsyncStream<Void>.Continuation
    // File-descriptor lifetime is owned exclusively by each source's
    // `setCancelHandler`, which calls `close(fd)` exactly once when the
    // source's cancel completes. We never close fds manually.
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?

    /// Creates and starts a watcher for ``fileURL``.
    ///
    /// - Parameter fileURL: The file to watch. The parent directory is
    ///   also observed so the watcher recovers when the file is created
    ///   or replaced after the watcher starts.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.queue = DispatchQueue(label: "com.cmux.json-config-file-watcher")
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        self.events = stream
        self.continuation = continuation
        Task { await self.start() }
    }

    deinit {
        // DispatchSource.cancel() is thread-safe; safe to call from deinit.
        fileSource?.cancel()
        directorySource?.cancel()
        continuation.finish()
    }

    /// Stops the watcher and finishes its ``events`` stream.
    ///
    /// Subsequent dispatch events are ignored. Idempotent.
    public func stop() {
        fileSource?.cancel()
        fileSource = nil
        directorySource?.cancel()
        directorySource = nil
        continuation.finish()
    }

    // MARK: - Private

    private func start() {
        attachDirectorySource()
        tryAttachFileSource()
    }

    /// Reacts to a parent-directory change. The file may have just been
    /// created or replaced; reattach the file-level source so we observe
    /// the new inode, then yield an event so consumers reread.
    private func handleDirectoryEvent() {
        tryAttachFileSource()
        continuation.yield(())
    }

    /// Reacts to a file-level change. Yields; consumers reread.
    private func handleFileEvent() {
        continuation.yield(())
    }

    private func attachDirectorySource() {
        let parentFD = open(fileURL.deletingLastPathComponent().path, O_EVTONLY)
        guard parentFD >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: parentFD,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.handleDirectoryEvent() }
        }
        source.setCancelHandler { close(parentFD) }
        source.resume()
        directorySource = source
    }

    /// Re-attaches the file-level source after a directory event.
    ///
    /// When we replace ``fileSource``, the previous source's
    /// `setCancelHandler` is responsible for closing its own captured fd.
    /// We never close fds manually here.
    private func tryAttachFileSource() {
        let fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileSource?.cancel()
        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .attrib],
            queue: queue
        )
        newSource.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.handleFileEvent() }
        }
        newSource.setCancelHandler { close(fd) }
        newSource.resume()
        fileSource = newSource
    }
}
