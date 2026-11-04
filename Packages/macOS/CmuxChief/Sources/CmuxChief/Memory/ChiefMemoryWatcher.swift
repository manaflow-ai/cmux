public import Dispatch
import Foundation

/// Reports changes to Chief's memory files from any writer (the app, the
/// `cmux chief memory` CLI, an editor) through file-system event sources,
/// never polling.
///
/// One vnode source watches the memory directory, which catches files being
/// created and the rename that `forget` and an atomic save do. One source per
/// file catches appends (`add` writes in place). After every event the file
/// sources are opened again, because a rename leaves the old source on a
/// replaced inode.
///
/// `onChange` runs on `queue` and may run more than once for one write;
/// readers re-read the files, which is cheap.
///
/// ```swift
/// let watcher = ChiefMemoryWatcher(paths: paths, queue: .main) { reload() }
/// watcher.start()
/// ```
public final class ChiefMemoryWatcher: @unchecked Sendable {
    // Every stored property below is touched only on `queue`.
    private let paths: ChiefMemoryPaths
    private let queue: DispatchQueue
    private let onChange: @Sendable () -> Void
    private var directorySource: (any DispatchSourceFileSystemObject)?
    private var fileSources: [any DispatchSourceFileSystemObject] = []
    private var running = false

    /// Creates a watcher; nothing is watched until ``start()``.
    ///
    /// - Parameters:
    ///   - paths: The memory files to watch.
    ///   - queue: Where the sources and `onChange` run (a serial queue).
    ///   - onChange: Called after the directory or a memory file changed.
    public init(paths: ChiefMemoryPaths, queue: DispatchQueue, onChange: @escaping @Sendable () -> Void) {
        self.paths = paths
        self.queue = queue
        self.onChange = onChange
    }

    deinit {
        directorySource?.cancel()
        for source in fileSources { source.cancel() }
    }

    /// Creates the memory directory when missing and starts watching. Idempotent.
    public func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            try? FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            directorySource = makeSource(path: paths.directory.path, mask: [.write, .delete, .rename])
            armFiles()
        }
    }

    /// Stops watching. Idempotent; ``start()`` may run again after it.
    public func stop() {
        queue.async { [self] in
            running = false
            directorySource?.cancel()
            directorySource = nil
            for source in fileSources { source.cancel() }
            fileSources = []
        }
    }

    // MARK: Internals

    private func armFiles() {
        for source in fileSources { source.cancel() }
        fileSources = [paths.facts, paths.person, paths.instructions].compactMap {
            makeSource(path: $0.path, mask: [.write, .extend, .delete, .rename, .attrib])
        }
    }

    private func makeSource(path: String, mask: DispatchSource.FileSystemEvent)
        -> (any DispatchSourceFileSystemObject)? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: queue)
        source.setEventHandler { [weak self] in self?.changed() }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func changed() {
        guard running else { return }
        armFiles()
        onChange()
    }
}
