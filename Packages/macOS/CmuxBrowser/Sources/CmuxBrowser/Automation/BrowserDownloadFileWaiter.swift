public import Foundation

/// The terminal outcome of waiting for a `browser.download.wait` target file to
/// become non-empty: the file reached a positive byte size within the budget
/// (``ready``), the budget elapsed first (``timeout``), or the directory watcher
/// could not be installed (``watcherSetupFailed``, carrying the `open(2)` errno).
///
/// `Sendable` because the wait runs on the nonisolated socket-worker lane and the
/// outcome is handed back across that boundary.
public enum BrowserDownloadFileWaitOutcome: Sendable, Equatable {
    /// The watched path exists with a byte size greater than zero.
    case ready

    /// The timeout budget elapsed before the path became non-empty.
    case timeout

    /// `open(2)` on the enclosing directory failed; the associated value is the
    /// captured `errno`.
    case watcherSetupFailed(errnoCode: Int32)
}

/// Blocks the calling (nonisolated socket-worker) thread until a browser
/// download's destination file exists with a positive byte size, or a timeout
/// elapses.
///
/// This is the stateless file-readiness half of the `browser.download.wait`
/// command, lifted byte-faithfully out of `TerminalController`'s
/// `v2WaitForDownloadFile`. The orchestration around it (param parsing, surface
/// resolution, the `NotificationCenter`-backed download-event wait) stays on the
/// app target because it reaches live `TabManager`/`Workspace` state through the
/// main actor; only this purely filesystem-bound waiter moves down.
///
/// A real instance value type, constructed at the call site
/// (`BrowserDownloadFileWaiter().wait(...)`), not a static-only namespace: its
/// readiness check and wait loop are instance methods, satisfying the refactor's
/// "no static-method utility types" discipline. It holds no mutable state and is
/// `Sendable`. Readiness is resolved against `FileManager.default` exactly as the
/// legacy body did. All methods are `nonisolated`: the only caller is the
/// socket-worker lane, which never touches the main actor for this work.
public struct BrowserDownloadFileWaiter: Sendable {
    /// Creates a download-file waiter.
    public init() {}

    /// Whether `path` currently exists with a byte size greater than zero. The
    /// download is only considered complete once the file has real bytes, not at
    /// the moment a zero-length placeholder appears.
    public func pathIsReady(_ path: String) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path),
              let attrs = try? fileManager.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else {
            return false
        }
        return size.intValue > 0
    }

    /// Waits up to `timeout` seconds for `path` to become non-empty.
    ///
    /// Returns immediately when the file is already ready. Otherwise it installs
    /// a `DispatchSource` directory watcher on the enclosing folder, re-checking
    /// readiness on every filesystem event, and falls back to a final readiness
    /// probe if the timeout fires first. Setup failure (the directory could not be
    /// opened) is reported as ``BrowserDownloadFileWaitOutcome/watcherSetupFailed``.
    public func wait(
        forDownloadAt path: String,
        timeout: TimeInterval
    ) -> BrowserDownloadFileWaitOutcome {
        if pathIsReady(path) {
            return .ready
        }

        let watchedPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let fd = open(watchedPath, O_EVTONLY)
        guard fd >= 0 else {
            return .watcherSetupFailed(errnoCode: errno)
        }

        let lock = NSLock()
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var finished = false
        nonisolated(unsafe) var ready = false
        let finishOnce: @Sendable (Bool) -> Void = { value in
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            ready = value
            lock.unlock()
            semaphore.signal()
        }

        let watcherQueue = DispatchQueue(label: "com.cmux.browser.download.wait.file")
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .link, .rename],
            queue: watcherQueue
        )
        // `@Sendable` so Dispatch can invoke the handler off the formation
        // context without the closure-inherits-isolation SIGTRAP.
        let isReady: @Sendable () -> Bool = { self.pathIsReady(path) }
        source.setEventHandler {
            if isReady() {
                finishOnce(true)
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        if pathIsReady(path) {
            finishOnce(true)
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            finishOnce(pathIsReady(path))
        }
        source.cancel()
        return ready ? .ready : .timeout
    }
}
