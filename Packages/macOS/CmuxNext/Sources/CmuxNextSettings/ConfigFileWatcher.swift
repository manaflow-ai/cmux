public import Foundation

/// Watches one file for changes with kernel vnode events (no polling).
///
/// Editors save in different ways: in place (write), atomic rename over the
/// file, or delete and recreate. The watcher observes the file itself and
/// its directory, and re-opens the file source whenever the directory
/// changes, so every save style reports a change. When the directory does
/// not exist yet it watches the nearest existing ancestor and moves down as
/// directories appear. `onChange` runs on a private serial queue; bursts of
/// events call it several times, so consumers should read the file's latest
/// state rather than count events.
public final class ConfigFileWatcher: @unchecked Sendable {
    public let url: URL
    private let queue = DispatchQueue(label: "com.cmuxterm.next.settings.watcher")
    private let onChange: @Sendable () -> Void
    // Queue-confined state.
    private var fileSource: (any DispatchSourceFileSystemObject)?
    private var directorySource: (any DispatchSourceFileSystemObject)?
    private var watchedDirectory: URL?
    private var fileIdentity: (dev: dev_t, ino: ino_t)?
    private var isStopped = false

    public init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    deinit {
        fileSource?.cancel()
        directorySource?.cancel()
    }

    /// Arms the watch, then reports one change so the consumer reads the
    /// file after the watch exists (a save between the consumer's first
    /// read and arming would otherwise be missed).
    public func start() {
        queue.async { [self] in
            isStopped = false
            rearm()
            onChange()
        }
    }

    public func stop() {
        queue.sync {
            isStopped = true
            fileSource?.cancel()
            fileSource = nil
            directorySource?.cancel()
            directorySource = nil
            watchedDirectory = nil
            fileIdentity = nil
        }
    }

    // MARK: - Queue-confined

    private func rearm() {
        guard !isStopped else { return }
        let target = url.resolvingSymlinksInPath()
        // A deeper directory can appear between choosing one and arming its
        // source (mkdir -p), so re-check until the choice is stable.
        var directory = nearestExistingDirectory(for: target.deletingLastPathComponent())
        while directory != watchedDirectory {
            directorySource?.cancel()
            directorySource = makeSource(path: directory.path, events: [.write, .delete, .rename, .link]) { [weak self] _ in
                self?.directoryChanged()
            }
            watchedDirectory = directory
            directory = nearestExistingDirectory(for: target.deletingLastPathComponent())
        }
        let identity = Self.identity(of: target.path)
        let identityChanged = identity?.dev != fileIdentity?.dev || identity?.ino != fileIdentity?.ino
        if fileSource == nil || identityChanged {
            fileSource?.cancel()
            fileSource = identity == nil ? nil : makeSource(
                path: target.path,
                events: [.write, .extend, .delete, .rename, .attrib, .revoke]
            ) { [weak self] events in
                self?.fileChanged(events)
            }
            fileIdentity = identity
        }
    }

    private func directoryChanged() {
        let before = fileIdentity
        rearm()
        let after = fileIdentity
        // A rename over the file or a create/delete changes its identity.
        if before?.dev != after?.dev || before?.ino != after?.ino {
            onChange()
        }
    }

    private func fileChanged(_ events: DispatchSource.FileSystemEvent) {
        if !events.isDisjoint(with: [.delete, .rename, .revoke]) {
            fileSource?.cancel()
            fileSource = nil
            fileIdentity = nil
            rearm()
        }
        onChange()
    }

    private func makeSource(
        path: String,
        events: DispatchSource.FileSystemEvent,
        handler: @escaping @Sendable (DispatchSource.FileSystemEvent) -> Void
    ) -> (any DispatchSourceFileSystemObject)? {
        let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: events, queue: queue)
        source.setEventHandler { [weak source] in
            handler(source?.data ?? [])
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private func nearestExistingDirectory(for directory: URL) -> URL {
        var candidate = directory
        var isDirectory: ObjCBool = false
        while !(FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) && isDirectory.boolValue) {
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }
        return candidate
    }

    private static func identity(of path: String) -> (dev: dev_t, ino: ino_t)? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return (info.st_dev, info.st_ino)
    }
}
