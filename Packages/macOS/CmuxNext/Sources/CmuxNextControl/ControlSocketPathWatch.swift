import CmuxNextCompat
import CmuxNextWakeups
import Darwin
import Foundation
import os

/// Notices that a control socket's file is gone and asks for it back.
///
/// A host's /tmp cleaner deleted a running app's `/tmp/cmux-debug-<tag>.sock`
/// at the same hour two nights running (readiness soak, hq#1870): the app kept
/// listening on the unlinked inode and no client could connect until a
/// relaunch. This watches with kqueue (no timer) the entry at the path itself
/// when it can be opened (a symlink, such as the /tmp compatibility link:
/// `O_SYMLINK` opens the link, not its target), so files other processes write
/// beside it wake nothing; it is watched again after every change, since a
/// put-back entry is a new file. A socket file cannot be opened, so for one the
/// watch falls back to its directory (the quiet per-user state folder); so does
/// a path with nothing at it. A directory watch moves back to following the
/// entry as soon as an event finds one it can open (someone else's link or file
/// put at the path, a link restored by another path). On each event it runs
/// one `lstat` on `queue` and calls `onMissing` only when nothing is at the
/// path (or, for a yielding watch, when the listener that held it ended; see
/// below); a path that exists is otherwise left alone, whoever owns it.
///
/// A directory watch on a shared directory (/tmp) wakes on every write there by
/// any process. It is kept only where it is the point: this app's own socket at
/// a socket-path override in /tmp (the hq#1870 cleaner case), logged once so
/// idle measurements can see it. A watch made with `yieldsToHeldPath` (the /tmp
/// compatibility link) does not watch the shared directory while another app's
/// live socket holds the path (a classic cmux build of the same channel or tag):
/// the link cannot be made while that socket is there, and it goes when its
/// listener ends. So the watch follows the listener's process (its pid from the
/// socket, `LOCAL_PEERPID`; one kevent at its exit, nothing before): at the exit
/// `onMissing` runs whether the socket file went or was left behind stale (the
/// link's restore replaces a stale socket of this user), and the watch follows
/// whatever is at the path then. `LOCAL_PEERPID` reports the socket's last user,
/// not a guaranteed listener: that process may have exited while one that
/// inherited the descriptor keeps the socket accepting. A pid whose exit the
/// watch has already handled is never followed again, so a live socket that
/// keeps naming it settles on the directory watch instead of following it in a
/// loop.
///
/// A held path with no listener to follow keeps the directory watch, logged
/// once, and records the held file's device and inode, read after the watch is
/// armed, so a file that replaces the probed one is always an event. What a
/// directory event that finds the same file does depends on the probe:
/// - An outcome that is a fact about the file while it is there is not probed
///   again (two `lstat`s per event, no connect to the other app's socket, no new
///   watch): a socket that accepts but names no pid to follow (none, not a live
///   process, or a pid whose exit was handled), and a connect the file itself
///   refuses (`EACCES`, `EPERM`, `ENAMETOOLONG`, `EPROTOTYPE`, `ENOTSOCK`).
/// - Any other outcome can change with no event in the directory, so the next
///   event probes the same file again (one non-blocking connect that fails at
///   once and takes no backlog slot): a refused connect (on macOS: no listener,
///   a socket bound but not listening yet, or a live listener whose accept queue
///   is full) and a connect that fails for the moment (`EAGAIN`, `EINTR`,
///   `ENOBUFS`, `EMFILE`, ...).
///
/// The link's restore replaces a stale socket of this user (refused), so a
/// refused socket of this user is given to it only when the watch did not see
/// the file appear: the file at the path when the watch starts, and the file a
/// followed listener left at its exit. A socket that appears while the watch
/// runs is often a live app between bind() and listen() (a classic cmux binds,
/// chmods, then listens; this app's server renames its socket into place, then
/// listens), and the restore would unlink it. Refused is the staleness rule the
/// restore itself applies (the same as
/// ``ControlSocketServer/reclaimStalePath(_:)``), so this watch never replaces a
/// file the restore would not.
///
/// Known limits: nothing reports the end of a held socket's listener that the
/// watch cannot follow (the process that inherited the descriptor is not known).
/// When it ends and leaves its file behind, the file is the same one, so the
/// directory watch stays for the rest of the run, waking on every /tmp write (two
/// `lstat`s each, plus one refused connect from then on), and the link is not
/// made until relaunch. The same holds for a socket that appeared while the
/// watch ran and was left stale before it ever listened
/// (plans/cmux-next/idle-wakeups.md).
///
/// Every watch is made and swapped on `queue`, the queue its events run on, so
/// an event never sees a half-installed watch and no older watch replaces a
/// newer one.
///
/// `onMissing` returns whether the socket is back. A restore that keeps
/// failing would re-trigger itself (its own bind creates and removes a staging
/// directory beside the path), so after ``maxFailedRestores`` failures in a
/// row the watch ignores events and tries again after a capped backoff
/// (1 s doubling to 60 s), until a restore works. Deleting or renaming the
/// directory itself is not followed: the directory is /tmp or the per-user
/// state folder.
final class ControlSocketPathWatch: Sendable {
    static let maxFailedRestores = 3

    let path: String
    /// The path's directory.
    private let directory: String
    private let queue: DispatchQueue
    private let onMissing: @Sendable () -> Bool
    /// Follow the listener of a foreign live socket that holds the path in a shared directory,
    /// not the directory.
    private let yieldsToHeldPath: Bool
    /// Connects to the socket at a path to see who holds it (``ControlSocketServer/probe(_:)``;
    /// tests pass a stand-in).
    private let probe: @Sendable (String) -> ControlSocketServer.ProbeResult
    // Lock carve-out: stop() runs off `queue` and must cancel the installed watch synchronously
    // (deinit); held only to swap one small value, never across a call out.
    private let installed = Mutex(InstalledWatch())
    // Lock carve-out: read and written synchronously by checkPath on `queue` and by the retry
    // timer's handler; a tiny struct, never held across a call out.
    private let failures = Mutex(Failures())
    /// The retry after ``maxFailedRestores`` failures in a row.
    private let retry = DemandTimer(owner: "ControlSocketPathWatch.retry")
    #if DEBUG
    /// Path checks run so far: each is one wakeup of `queue` (tests count them).
    let checks = Atomic<Int>(0)
    /// Watches installed so far: each is a new kqueue source (tests count them).
    let installs = Atomic<Int>(0)
    #endif

    struct Failures {
        var inARow = 0
        var waiting = false
        var backoff = Backoff(initial: .seconds(1), maximum: .seconds(60))
    }

    /// The installed watch (a file system source, or the process source of a holder's listener)
    /// and, for a yielding watch's directory watch, the file at the path it cannot follow. One
    /// value: installing any other watch forgets the file.
    private struct InstalledWatch {
        var source: InstalledSource?
        var held: HeldFile?
    }

    /// The file a yielding watch's directory watch found at the path and cannot follow.
    private struct HeldFile: Equatable {
        /// Read after the directory watch was armed: a file that replaces it is an event.
        var identity: FileIdentity
        /// Its last probe's outcome can change while the same file is there, with no event in
        /// the directory: each directory event probes it again (``isSettled(_:)`` is false).
        var reprobe: Bool
    }

    /// The installed watch's source, as the kind it was made: a file system source (the entry or
    /// its directory) or the process source of a holder's listener.
    private enum InstalledSource {
        case file(any DispatchSourceFileSystemObject)
        case process(any DispatchSourceProcess)

        func resume() {
            switch self {
            case .file(let source): source.resume()
            case .process(let source): source.resume()
            }
        }

        func cancel() {
            switch self {
            case .file(let source): source.cancel()
            case .process(let source): source.cancel()
            }
        }
    }

    init(
        path: String,
        queue: DispatchQueue,
        yieldsToHeldPath: Bool = false,
        probe: @escaping @Sendable (String) -> ControlSocketServer.ProbeResult = { ControlSocketServer.probe($0) },
        onMissing: @escaping @Sendable () -> Bool
    ) {
        self.path = path
        self.queue = queue
        self.yieldsToHeldPath = yieldsToHeldPath
        self.probe = probe
        self.onMissing = onMissing
        let parent = (path as NSString).deletingLastPathComponent
        directory = parent.isEmpty ? "." : parent
    }

    deinit {
        stop()
    }

    func start() {
        stopped.store(false, ordering: .sequentiallyConsistent)
        queue.async { [weak self] in
            guard let self else { return }
            // The file there now was not seen appearing: a stale socket of this user may be replaced.
            self.watch(mayRestoreStale: true)
            // Gone before the watch existed: no event will say so.
            var info = stat()
            if lstat(self.path, &info) != 0, errno == ENOENT, self.checkPath() { self.watch() }
        }
    }

    func stop() {
        retry.cancel()
        // Set before the swap below: a watch() that takes the lock after it sees it.
        stopped.store(true, ordering: .sequentiallyConsistent)
        installed.withLock { current in
            current.source?.cancel()
            current = InstalledWatch()
        }
    }

    /// Set by ``stop()``: a check in flight on `queue` then watches nothing again.
    private let stopped = Atomic<Bool>(true)

    /// The directory watch is on a shared directory, or the path is held there; logged once per watch.
    private let loggedSharedDirectory = Atomic<Bool>(false)

    /// The last holder pid whose exit ``holderEnded(_:)`` handled (0: none). A socket that still
    /// names it after that exit is held by some other process the pid does not identify.
    private let endedListener = Atomic<pid_t>(0)

    /// On `queue`: watches the entry at the path, or its directory when the entry cannot be
    /// opened (a socket file, nothing there), or for a yielding watch the listener of a live
    /// socket that holds the path; replaces the watch in place. `entryOnly`: keep the current
    /// watch unless the entry can be followed now. `mayRestoreStale`: the watch did not see the
    /// file at the path appear (``start()``), so a refused socket of this user there may be
    /// given to the restore.
    private func watch(entryOnly: Bool = false, mayRestoreStale: Bool = false) {
        dispatchPrecondition(condition: .onQueue(queue))
        let entry = open(path, O_EVTONLY | O_SYMLINK)
        if entry >= 0 {
            install(.entry(entry))
            return
        }
        if entryOnly { return }
        let descriptor = open(directory, O_EVTONLY)
        guard descriptor >= 0 else {
            // Without the watch a deleted socket stays gone until relaunch; say so once.
            let error = String(cString: strerror(errno))
            pathWatchLog.error("socket path watch off: cannot open \(self.directory, privacy: .public): \(error, privacy: .public)")
            return
        }
        let shared = Self.isShared(directory)
        // Armed and installed before the path is read below: any change after that read is an
        // event, which compares the file it finds with the one read here. A watch that follows
        // the holder, or the restore's own watch(), replaces it; events still queued for it then
        // never run (a cancelled source calls its handler no more).
        guard install(.directory(descriptor)) else { return }  // stopped: watches nothing, by design
        guard yieldsToHeldPath, let info = Self.lstatInfo(path) else {
            if shared { noteOnce("socket path watch on shared directory \(directory) for \(path): wakes on every write there") }
            return
        }
        // A file this watch cannot open holds the path (a socket file, mostly).
        if shared {
            yieldInSharedDirectory(to: info, mayRestoreStale: mayRestoreStale)
        } else {
            holdEntry(HeldFile(identity: FileIdentity(info), reprobe: false))
        }
    }

    /// On `queue`, with the directory watch on the shared directory installed: what a yielding
    /// watch does about `info`, the file at the path it cannot open, from one probe. Follows a
    /// live listener; gives a refused socket of this user to the restore when
    /// `mayRestoreStale`; else records the file on the directory watch (``HeldFile``).
    private func yieldInSharedDirectory(to info: stat, mayRestoreStale: Bool) {
        let probed = probe(path)
        switch probed {
        case .accepted(let listener?) where canFollow(listener):
            // Another app's live socket: nothing can be made there until its listener ends,
            // and watching /tmp would wake on every write by any process.
            followHolder(listener)
        case .refused where mayRestoreStale && Self.isOwnSocket(info) && !stopped.load(ordering: .sequentiallyConsistent):
            // A stale socket of this user the watch did not see appear: exactly what the
            // restore replaces. The watch() after it never gives a file to the restore.
            _ = onMissing()
            watch()
        default:
            let held = HeldFile(identity: FileIdentity(info), reprobe: !Self.isSettled(probed))
            guard holdEntry(held) else { return }
            noteOnce("socket path watch for \(path) keeps the shared directory \(directory): a socket it cannot follow holds the path (\(String(describing: probed))); wakes on every write there")
        }
    }

    /// `probed` is a fact about the held file that stays true while the same file is at the
    /// path, so a directory event that finds that file need not probe it again: a socket that
    /// accepts (here: naming no pid to follow), or a connect the file itself refuses. A refused
    /// connect is not (on macOS: no listener yet, or a live one whose accept queue is full), nor
    /// is any other error (one that lasts a moment, or one this list does not know).
    private static func isSettled(_ probed: ControlSocketServer.ProbeResult) -> Bool {
        switch probed {
        case .accepted: true
        case .refused: false
        case .inconclusive(let code): fileErrors.contains(code)
        }
    }

    /// Connect errors that come from the socket file itself (its mode, its type, its path).
    private static let fileErrors: Set<Int32> = [EACCES, EPERM, ENAMETOOLONG, EPROTOTYPE, ENOTSOCK]

    /// `listener`, the pid a live socket at the path names, is a holder to follow: a live process
    /// whose exit was not already handled (a socket that still names a handled pid is held by a
    /// process that inherited the descriptor).
    private func canFollow(_ listener: pid_t) -> Bool {
        listener != endedListener.load(ordering: .relaxed) && Self.isLive(listener)
    }

    /// On `queue`: follows the process `listener`, whose live socket holds the path; its exit
    /// is the one event that can free the path. Never calls ``watch(entryOnly:mayRestoreStale:)``
    /// itself except through ``holderEnded(_:)`` when the process ended before the arming.
    private func followHolder(_ listener: pid_t) {
        guard install(.holder(listener)) else { return }  // stopped: watches nothing, by design
        noteOnce("socket path watch for \(path) follows pid \(listener), whose live socket holds the path in \(directory); the link is made when it ends")
        // Ended between canFollow and the arming: no event may say so. holderEnded's watch()
        // never follows this pid again, so this runs at most once per pid.
        if !Self.isLive(listener) { holderEnded(listener) }
    }

    /// `pid` is a process that exists (`kill(pid, 0)` succeeds, or is refused for another
    /// user's process).
    private static func isLive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// What a watch follows. ``install(_:)`` makes the watch's source from it.
    private enum Target {
        /// The entry at the path, opened `O_EVTONLY | O_SYMLINK`: its delete, rename or revoke.
        case entry(Int32)
        /// The path's directory, opened `O_EVTONLY`: a write, rename or delete in it.
        case directory(Int32)
        /// The process whose live socket holds the path: its exit.
        case holder(pid_t)
    }

    /// On `queue`: makes the watch of `target`, resumes it and makes it the installed one,
    /// cancelling the one before (and forgetting its held file); false (and the new watch
    /// cancelled) once stopped. Its events run on `queue`, after this install.
    ///
    /// The source is made here, never passed in, and kept as its own kind (``InstalledSource``),
    /// never as `any DispatchSourceProtocol`. A dispatch source is not `Sendable`: one that came
    /// in as a parameter (even a `sending` one), or that was converted to that existential
    /// before the lock, is in the caller's region for Swift's region analysis, and the lock's
    /// `inout sending` value refuses it at the end of the lock's closure (Swift 6.2 to 6.4:
    /// "cannot be task-isolated at end of function"). A source made in this function is
    /// disconnected until the lock takes it.
    @discardableResult
    private func install(_ target: Target) -> Bool {
        let watch: InstalledSource
        switch target {
        case .entry(let descriptor):
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.delete, .rename, .revoke], queue: queue)
            // wakeup-allow: kqueue event on the entry, no timer; one lstat per event
            source.setEventHandler { [weak self] in self?.changed(followingEntry: true) }
            source.setCancelHandler { close(descriptor) }
            watch = .file(source)
        case .directory(let descriptor):
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: queue)
            // wakeup-allow: kqueue event on the directory, no timer; one lstat per event (two while a held file is recorded)
            source.setEventHandler { [weak self] in self?.changed(followingEntry: false) }
            source.setCancelHandler { close(descriptor) }
            watch = .file(source)
        case .holder(let listener):
            let source = DispatchSource.makeProcessSource(identifier: listener, eventMask: .exit, queue: queue)
            // wakeup-allow: one kevent when the holder's listener exits, no timer
            source.setEventHandler { [weak self] in self?.holderEnded(listener) }
            watch = .process(source)
        }
        // Resumed before it is published: an inactive source must never be cancelled or released.
        watch.resume()
        let done = installed.withLock { current -> Bool in
            guard !stopped.load(ordering: .sequentiallyConsistent) else { return false }
            current.source?.cancel()
            current = InstalledWatch(source: watch, held: nil)
            return true
        }
        if !done { watch.cancel() }
        #if DEBUG
        if done { installs.add(1, ordering: .relaxed) }
        #endif
        return done
    }

    /// On `queue`, while a yielding watch's directory watch is installed: records `held`, the
    /// file at the path it cannot follow, on that watch; false once stopped. Events run on
    /// `queue` too, so none sees the directory watch without it.
    @discardableResult
    private func holdEntry(_ held: HeldFile) -> Bool {
        installed.withLock { current -> Bool in
            guard !stopped.load(ordering: .sequentiallyConsistent) else { return false }
            current.held = held
            return true
        }
    }

    /// On `queue`: the listener `listener`, whose socket held the path, ended. Its socket file is
    /// gone, or left behind stale: either way the restore takes the path now (the link's
    /// replaces a stale socket of this user and leaves anything else), then the watch follows
    /// whatever is at the path. A socket there that still names `listener` is not followed
    /// again (``canFollow(_:)``), and the watch() after the restore never gives a file to the
    /// restore, so this never re-enters itself.
    private func holderEnded(_ listener: pid_t) {
        guard !stopped.load(ordering: .sequentiallyConsistent) else { return }
        endedListener.store(listener, ordering: .relaxed)
        let left = FileIdentity.at(path)
        if left != nil {
            // Whether it took the path needs no handling here: the watch() below follows what
            // the path holds now.
            _ = onMissing()
        } else {
            checkPath()
        }
        watch()
    }

    /// An event on `queue`. The entry a watch follows was deleted, renamed or revoked: whatever
    /// is at the path now (put back, or someone else's) is a new file, watched again. A
    /// directory watch moves to the entry whenever one it can follow is there. A file that
    /// appears here is never given to the restore (it may be a live app's socket before its
    /// listen()).
    private func changed(followingEntry: Bool) {
        let restored = checkPath()
        if followingEntry || restored {
            watch()
            return
        }
        guard !stopped.load(ordering: .sequentiallyConsistent), let info = Self.lstatInfo(path) else { return }
        if let held = installed.withLock({ $0.held }), held.identity == FileIdentity(info) {
            // The held file a yielding watch recorded is still there: nothing new to watch. It is
            // probed again only when its last outcome can change with no event here.
            if held.reprobe { yieldInSharedDirectory(to: info, mayRestoreStale: false) }
            return
        }
        // An entry it cannot follow is there now: a yielding watch moves to its listener.
        watch(entryOnly: !yieldsToHeldPath)
    }

    /// What is at `path` (not following a link), nil for nothing.
    private static func lstatInfo(_ path: String) -> stat? {
        var info = stat()
        return lstat(path, &info) == 0 ? info : nil
    }

    /// A socket file of this user: the only held file the link's restore replaces.
    private static func isOwnSocket(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFSOCK && info.st_uid == getuid()
    }

    /// A sticky, world-writable directory (/tmp): every process on the Mac writes there.
    private static func isShared(_ directory: String) -> Bool {
        var info = stat()
        return stat(directory, &info) == 0 && info.st_mode & S_ISVTX != 0 && info.st_mode & S_IWOTH != 0
    }

    /// Logs `message` once per watch, so idle measurements can see it.
    private func noteOnce(_ message: String) {
        guard !loggedSharedDirectory.exchange(true, ordering: .relaxed) else { return }
        pathWatchLog.notice("\(message, privacy: .public)")
    }

    /// Runs on `queue`, so a restore never overlaps the server's accept handler. True when it
    /// put the path back.
    @discardableResult
    private func checkPath(retrying: Bool = false) -> Bool {
        #if DEBUG
        checks.add(1, ordering: .relaxed)
        #endif
        if !retrying, failures.withLock({ $0.waiting }) { return false }  // backing off
        var info = stat()
        guard lstat(path, &info) != 0, errno == ENOENT, !stopped.load(ordering: .sequentiallyConsistent) else {
            failures.withLock { $0 = Failures() }
            return false
        }
        if onMissing() {
            failures.withLock { $0 = Failures() }
            return true
        }
        let delay = failures.withLock { state -> Duration? in
            state.inARow += 1
            guard state.inARow >= Self.maxFailedRestores else { return nil }
            state.waiting = true
            return state.backoff.next()
        }
        guard let delay else { return false }
        let queue = self.queue
        retry.schedule(after: delay) { [weak self] in
            guard let self else { return }
            queue.async { if self.checkPath(retrying: true) { self.watch() } }
        }
        return false
    }
}

private let pathWatchLog = Logger(subsystem: "com.cmuxterm.app.next", category: "control-socket")
