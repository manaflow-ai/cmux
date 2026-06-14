import Foundation

/// Watches a single file or directory for change events and exposes them as an
/// `AsyncStream<Void>`.
///
/// This is the single-path counterpart to ``RecursivePathWatcher``: it wraps
/// `DispatchSource.makeFileSystemObjectSource` (the kqueue-backed primitive for
/// per-descriptor file events on macOS, which has no async-native replacement)
/// rather than `FSEventStream`. Use it to react to changes to one path — a
/// config file, a settings file, a directory listing — where recursive subtree
/// watching is not needed.
///
/// **Recovery.** Alongside the path itself the watcher observes the *nearest
/// existing ancestor directory*, so its stream recovers when the path is created,
/// replaced, atomically saved, or when an intervening directory is created or
/// removed after the watcher starts (the path frequently does not exist on first
/// use). As ancestors appear the directory source migrates closer to the path,
/// and the path-level source reattaches to the current inode.
///
/// An optional leading-edge ``throttle`` coalesces a burst of events into a
/// single yield, driven through the injectable ``FileWatchClock`` (see
/// ``RecursivePathWatcher`` for the rationale and the deterministic test
/// pattern). With no throttle, every coalesced `DispatchSource` batch yields one
/// element.
///
/// ```swift
/// let watcher = FileWatcher(path: configPath, throttle: .milliseconds(300))
/// let task = Task { @MainActor in
///     for await _ in watcher.events { reloadFromDisk() }
/// }
/// // teardown
/// task.cancel()
/// await watcher.stop()
/// ```
public actor FileWatcher {
    /// Stream of change events. Yields when the watched path or a watched
    /// ancestor directory changes. Finishes when ``stop()`` is called or the
    /// watcher is deallocated.
    public nonisolated let events: AsyncStream<Void>

    private let path: String
    private let throttle: Duration?
    private let clock: any FileWatchClock
    // DispatchSource requires a queue; this is internal isolation only and never
    // exposed. Sources are owned by the actor and torn down on stop/deinit.
    private let queue: DispatchQueue
    private let continuation: AsyncStream<Void>.Continuation
    // The DispatchSource event handlers yield into this (a Sendable value), not
    // the actor, so the sources can be attached synchronously in `init`.
    private let rawContinuation: AsyncStream<Void>.Continuation
    // File-descriptor lifetime is owned by each source's `setCancelHandler`,
    // which calls `close(fd)` exactly once when the source's cancel completes.
    private var fileSource: (any DispatchSourceFileSystemObject)?
    private var directorySource: (any DispatchSourceFileSystemObject)?
    private var watchedDirectory: String?
    private var throttleTask: Task<Void, Never>?
    private var isStopped = false

    // OptionSet masks. Inlined (not stored as statics) because
    // `DispatchSource.FileSystemEvent` is not `Sendable`.
    private static var fileEventMask: DispatchSource.FileSystemEvent {
        [.write, .delete, .rename, .extend, .attrib]
    }
    private static var directoryEventMask: DispatchSource.FileSystemEvent {
        [.write, .rename, .delete]
    }

    /// Creates and starts a watcher for `path`.
    ///
    /// - Parameters:
    ///   - path: The file or directory to watch. Need not exist yet; the nearest
    ///     existing ancestor is observed so the stream recovers when it appears.
    ///   - throttle: Optional leading-edge coalescing window. `nil` (default)
    ///     yields one element per `DispatchSource` event batch.
    ///   - clock: The clock driving the throttle. Defaults to
    ///     ``SystemFileWatchClock``. Ignored when `throttle` is `nil`.
    public init(
        path: String,
        throttle: Duration? = nil,
        clock: any FileWatchClock = SystemFileWatchClock()
    ) {
        self.path = path
        self.throttle = throttle
        self.clock = clock
        self.queue = DispatchQueue(label: "com.cmux.file-watcher", qos: .utility)
        let (events, eventsContinuation) = AsyncStream<Void>.makeStream()
        self.events = events
        self.continuation = eventsContinuation
        let (rawEvents, rawContinuation) = AsyncStream<Void>.makeStream()
        self.rawContinuation = rawContinuation

        // Attach the sources synchronously so the watcher is already listening
        // when init returns. The handlers capture `rawContinuation` (Sendable),
        // not `self`, so this does not escape the actor mid-init.
        let directory = Self.nearestExistingDirectory(forPath: path)
        self.watchedDirectory = directory
        self.directorySource = Self.makeSource(
            forPath: directory,
            eventMask: Self.directoryEventMask,
            queue: queue,
            rawContinuation: rawContinuation
        )
        self.fileSource = Self.makeSource(
            forPath: path,
            eventMask: Self.fileEventMask,
            queue: queue,
            rawContinuation: rawContinuation
        )

        // Drain raw events through the actor (reattach sources, then
        // yield/throttle). Started last so init touches no isolated state after
        // `self` escapes; ends when `rawEvents` finishes (stop/deinit).
        Task { [weak self] in
            for await _ in rawEvents {
                await self?.handleRawEvent()
            }
        }
    }

    /// Stops the watcher, tears down its sources, and finishes ``events``.
    /// Idempotent.
    public func stop() {
        isStopped = true
        throttleTask?.cancel()
        throttleTask = nil
        fileSource?.cancel()
        fileSource = nil
        directorySource?.cancel()
        directorySource = nil
        rawContinuation.finish()
        continuation.finish()
    }

    deinit {
        // DispatchSource.cancel() is thread-safe; safe from deinit.
        fileSource?.cancel()
        directorySource?.cancel()
        throttleTask?.cancel()
        rawContinuation.finish()
        continuation.finish()
    }

    // MARK: - Private

    /// Walks up from `path`'s parent to the first existing directory, so the
    /// watcher can observe an ancestor while the path itself does not exist.
    /// Falls back to the current directory.
    private static func nearestExistingDirectory(forPath path: String) -> String {
        let fileManager = FileManager.default
        var current = (path as NSString).deletingLastPathComponent
        var seen = Set<String>()
        while !current.isEmpty {
            let standardized = (current as NSString).standardizingPath
            guard seen.insert(standardized).inserted else { break }
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: standardized, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return standardized
            }
            let parent = (standardized as NSString).deletingLastPathComponent
            if parent == standardized || parent.isEmpty { break }
            current = parent
        }
        return fileManager.currentDirectoryPath
    }

    /// Builds, resumes, and returns a source for `path`, or `nil` if it cannot
    /// be opened. The event handler captures only `rawContinuation`.
    private static func makeSource(
        forPath path: String,
        eventMask: DispatchSource.FileSystemEvent,
        queue: DispatchQueue,
        rawContinuation: AsyncStream<Void>.Continuation
    ) -> (any DispatchSourceFileSystemObject)? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: eventMask,
            queue: queue
        )
        source.setEventHandler { rawContinuation.yield(()) }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    /// Reacts to a raw source event: re-evaluate which ancestor directory to
    /// watch and reattach the path source to the current inode, then signal a
    /// change (throttled if configured).
    private func handleRawEvent() {
        guard !isStopped else { return }
        reattachSources()
        guard let throttle else {
            continuation.yield(())
            return
        }
        // Leading-edge throttle: the first event arms one bounded delay; events
        // during the window coalesce (the `throttleTask == nil` guard).
        guard throttleTask == nil else { return }
        let clock = self.clock
        throttleTask = Task { [weak self] in
            try? await clock.sleep(for: throttle)
            await self?.flushThrottle()
        }
    }

    private func flushThrottle() {
        throttleTask = nil
        guard !isStopped else { return }
        continuation.yield(())
    }

    /// Moves the directory source to the current nearest existing ancestor (if it
    /// changed) and reattaches the path source to the current inode. Each previous
    /// source's `setCancelHandler` closes its own fd.
    private func reattachSources() {
        let directory = Self.nearestExistingDirectory(forPath: path)
        if directory != watchedDirectory {
            directorySource?.cancel()
            directorySource = Self.makeSource(
                forPath: directory,
                eventMask: Self.directoryEventMask,
                queue: queue,
                rawContinuation: rawContinuation
            )
            watchedDirectory = directory
        }
        let newFileSource = Self.makeSource(
            forPath: path,
            eventMask: Self.fileEventMask,
            queue: queue,
            rawContinuation: rawContinuation
        )
        fileSource?.cancel()
        fileSource = newFileSource
    }
}
