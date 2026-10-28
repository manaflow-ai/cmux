import CmuxNextCompat
import CmuxNextWakeups
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
///
/// ``start(reportInitialChange:)`` and ``stop()`` never wait for that queue: the
/// watch's opens and stats run there, never on the caller's thread (the main
/// thread), as Chrome's `FilePathWatcher` sets up its kqueue on a sequence that may
/// block (base/files/file_path_watcher_kqueue.cc).
///
/// In Debug and bench builds the watch is in the launch's arm census (startup-queue.py arms, p08-startup-085): its
/// first arm and its first event, under the line that made the watcher.
public final class ConfigFileWatcher: @unchecked Sendable { // crash-allow: the sources and what they watch change only on the serial `queue` (arm, disarm, the event handlers) and in deinit; `run` is a Mutex, the rest is immutable
    public let url: URL
    private let queue: DispatchQueue
    private let onChange: @Sendable () -> Void
    /// Which start is current: set by the caller's start and stop, read on the queue.
    private let run = Mutex(Run())
    /// The watch's record in the arm census (nothing in Release).
    private let census: ArmCensusWatch
    // Queue-confined state.
    private var fileSource: (any DispatchSourceFileSystemObject)?
    private var directorySource: (any DispatchSourceFileSystemObject)?
    private var watchedDirectory: URL?
    private var fileIdentity: (dev: dev_t, ino: ino_t)?
    private var marked = Mark.unset

    private struct Run {
        /// Bumped by every start and stop: an arm queued before a later call does nothing.
        var generation: UInt64 = 0
        var running = false
    }

    /// When the arm reports its one change.
    private enum InitialChange {
        case always
        /// When the file or its folder changed at or after this time (a quiet start).
        case changedSince(timespec)
        /// When the file's state differs from the ``mark()``.
        case differsFromMark
    }

    /// The file at a ``mark()``: nil when it did not exist.
    private struct FileState: Equatable {
        let dev: dev_t
        let ino: ino_t
        let ctimeSeconds: Int
        let ctimeNanoseconds: Int
    }

    private enum Mark {
        case unset
        case recorded(FileState?)
    }

    /// - Parameters:
    ///   - url: The file watched.
    ///   - file: The line that made the watcher, named by the arm census (leave the default).
    ///   - line: See `file`.
    ///   - onChange: Runs on the watcher's queue after each change.
    public convenience init(url: URL, file: StaticString = #fileID, line: UInt = #line, onChange: @escaping @Sendable () -> Void) {
        self.init(url: url, queue: DispatchQueue(label: "com.cmuxterm.next.settings.watcher", qos: .utility),
                  file: file, line: line, onChange: onChange)
    }

    /// A watcher whose arm, events and `onChange` run on `queue`, a serial queue (tests hold it to
    /// order a save before the arm); `ledger`'s arm census records the watch.
    init(url: URL, queue: DispatchQueue, ledger: WakeupLedger = .shared, file: StaticString = #fileID, line: UInt = #line,
         onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.queue = queue
        self.onChange = onChange
        census = ArmCensusWatch(ledger: ledger, .watcher, owner: "ConfigFileWatcher", file: file, line: line)
    }

    deinit {
        fileSource?.cancel()
        directorySource?.cancel()
    }

    /// Arms the watch, then reports one change so the consumer reads the file
    /// after the watch exists.
    public func start() {
        start(reportInitialChange: true)
    }

    /// Arms the watch on the watcher's queue and returns at once. With the initial change on, it is
    /// reported there after the watch exists, so a consumer that reads the file then loses no save.
    /// A consumer that already has a current snapshot turns it off and hears only later edits; a
    /// save made after this call but before the watch exists is one of them: the arm compares the
    /// file's and its folder's change times with this call's time. A ``stop()`` after it ends the watch.
    public func start(reportInitialChange: Bool = true) {
        begin(reportInitialChange ? .always : .changedSince(Self.wallClock()))
    }

    /// Records the file's state on the watcher's queue (its identity and status change time, or
    /// that it does not exist), for a consumer that read the file now and arms the watch later with
    /// ``startFromMark()``. Nothing is watched until then.
    public func mark() {
        queue.async { [self] in marked = .recorded(Self.state(of: url.resolvingSymlinksInPath().path)) }
    }

    /// Arms the watch on the watcher's queue and returns at once, for a consumer that called
    /// ``mark()`` when it read the file and arms later (a launch watch posted after startup). One
    /// change is reported when the file's state differs from the mark: written, replaced, created or
    /// deleted. Entries added to or removed from its folder are not changes of the file, so the gap
    /// between the mark and the arm can be long. Without a mark it reports one change.
    public func startFromMark() {
        begin(.differsFromMark)
    }

    private func begin(_ initial: InitialChange) {
        let generation = run.withLock { run in
            run.generation &+= 1
            run.running = true
            return run.generation
        }
        queue.async { [self] in arm(generation, initial) }
    }

    /// The same as ``start(reportInitialChange:)``, which does not wait either.
    public func startWithoutWaiting(reportInitialChange: Bool = true) {
        start(reportInitialChange: reportInitialChange)
    }

    /// Ends the watch and returns at once; the queue closes the sources. Not a fence: a report
    /// that already started on the queue may still call `onChange` once after this returns, but no
    /// later event is reported. Consumers hop to their own actor and drop a late call there.
    public func stop() {
        run.withLock { run in
            run.generation &+= 1
            run.running = false
        }
        queue.async { [self] in disarm() }
    }

    // MARK: - Queue-confined

    /// Arms the watch of start `generation` unless a later start or stop came, then reports one
    /// change as `initial` says.
    private func arm(_ generation: UInt64, _ initial: InitialChange) {
        guard run.withLock({ $0.generation == generation }) else { return }
        rearm()
        census.armed()
        switch initial {
        case .always:
            break
        case .changedSince(let time):
            if !changed(since: time) { return }
        case .differsFromMark:
            defer { marked = .unset }
            if case .recorded(let state) = marked, state == Self.state(of: url.resolvingSymlinksInPath().path) { return }
        }
        report()
    }

    private func disarm() {
        guard !run.withLock({ $0.running }) else { return }
        fileSource?.cancel()
        fileSource = nil
        directorySource?.cancel()
        directorySource = nil
        watchedDirectory = nil
        fileIdentity = nil
    }

    /// Calls `onChange` while a start is current (a ``stop()`` between the check and the call does
    /// not stop that one call).
    private func report() {
        if run.withLock({ $0.running }) { onChange() }
    }

    private func rearm() {
        guard run.withLock({ $0.running }) else { return }
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
        census.fired()
        let before = fileIdentity
        rearm()
        let after = fileIdentity
        // A rename over the file or a create/delete changes its identity.
        if before?.dev != after?.dev || before?.ino != after?.ino {
            report()
        }
    }

    private func fileChanged(_ events: DispatchSource.FileSystemEvent) {
        census.fired()
        if !events.isDisjoint(with: [.delete, .rename, .revoke]) {
            fileSource?.cancel()
            fileSource = nil
            fileIdentity = nil
            rearm()
        }
        report()
    }

    /// Whether the file changed (its status change time) or its watched folder gained, lost or
    /// renamed an entry (its modification time) at or after `time`.
    private func changed(since time: timespec) -> Bool {
        let file = url.resolvingSymlinksInPath().path
        let folder = watchedDirectory?.path
        return blockingCall(.fsMetadata) {
            var info = stat()
            if stat(file, &info) == 0, Self.isAtOrAfter(info.st_ctimespec, time) { return true }
            guard let folder, stat(folder, &info) == 0 else { return false }
            return Self.isAtOrAfter(info.st_mtimespec, time)
        }
    }

    private func makeSource(
        path: String,
        events: DispatchSource.FileSystemEvent,
        handler: @escaping @Sendable (DispatchSource.FileSystemEvent) -> Void
    ) -> (any DispatchSourceFileSystemObject)? {
        let descriptor = blockingOpen(path, O_EVTONLY | O_CLOEXEC)
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

    /// The file system's clock: file change times come from it (`vfs_timestamp`).
    private static func wallClock() -> timespec {
        var now = timespec()
        clock_gettime(CLOCK_REALTIME, &now)
        return now
    }

    private static func isAtOrAfter(_ time: timespec, _ reference: timespec) -> Bool {
        time.tv_sec != reference.tv_sec ? time.tv_sec > reference.tv_sec : time.tv_nsec >= reference.tv_nsec
    }

    /// The file's identity and status change time (a write, a chmod), or nil when it does not exist.
    private static func state(of path: String) -> FileState? {
        blockingCall(.fsMetadata) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            return FileState(dev: info.st_dev, ino: info.st_ino, ctimeSeconds: Int(info.st_ctimespec.tv_sec),
                             ctimeNanoseconds: Int(info.st_ctimespec.tv_nsec))
        }
    }

    private static func identity(of path: String) -> (dev: dev_t, ino: ino_t)? {
        var info = stat()
        guard blockingStat(path, &info) == 0 else { return nil }
        return (info.st_dev, info.st_ino)
    }
}
