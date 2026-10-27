import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextTrace
import CmuxNextWakeups
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
#if canImport(os)
import os
#endif

/// Notices that a control socket's file is gone and asks for it back.
///
/// A host's /tmp cleaner deleted a running app's `/tmp/cmux-debug-<tag>.sock`
/// at the same hour two nights running (readiness soak, hq#1870): the app kept
/// listening on the unlinked inode and no client could connect until a
/// relaunch. This watches with kqueue (inotify on Linux; no timer) the entry at the path itself
/// when it can be opened (a symlink, such as the /tmp compatibility link:
/// `O_SYMLINK` opens the link, not its target), so files other processes write
/// beside it wake nothing; it is watched again after every change, since a
/// put-back entry is a new file. A socket file cannot be opened on Darwin (Linux's
/// inotify follows one, ``makeSource(watching:followingEntry:)``), so for one the
/// watch falls back to its directory (the quiet per-user state folder); so does
/// a path with nothing at it. A directory watch moves back to following the
/// entry as soon as an event finds one it can open (someone else's link or file
/// put at the path, a link restored by another path). On each event it runs
/// one `lstat` on `queue` and calls `onMissing` only when nothing is at the
/// path; a path that exists is left alone, whoever owns it.
///
/// A directory watch on a shared directory (/tmp) wakes on every write there by
/// any process. It is kept only where it is the point: this app's own socket at
/// a socket-path override in /tmp (the hq#1870 cleaner case), logged once so
/// idle measurements can see it. A watch made with `yieldsToHeldPath` (the /tmp
/// compatibility link) watches nothing while an entry it cannot follow holds
/// the path in a shared directory (another app's live socket, such as a classic
/// cmux build of the same channel or tag): the link cannot be made while that
/// entry is there, so the link is dropped for this run and logged once.
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
    private let queue: DispatchQueue
    private let onMissing: @Sendable () -> Bool
    /// Watch nothing while a foreign entry holds the path in a shared directory.
    private let yieldsToHeldPath: Bool
    // Lock carve-out: stop() runs off `queue` and must cancel the installed watch synchronously
    // (deinit); held only to swap one reference.
    private let source = Mutex<WatchSource?>(nil)
    // Lock carve-out: read and written synchronously by checkPath on `queue` and by the retry
    // timer's handler; a tiny struct, never held across a call out.
    private let failures = Mutex(Failures())
    /// The retry after ``maxFailedRestores`` failures in a row.
    private let retry = DemandTimer(owner: "ControlSocketPathWatch.retry")
    #if DEBUG
    /// Path checks run so far: each is one wakeup of `queue` (tests count them).
    let checks = Atomic<Int>(0)
    #endif

    struct Failures {
        var inARow = 0
        var waiting = false
        var backoff = Backoff(initial: .seconds(1), maximum: .seconds(60))
    }

    /// One watch's dispatch source: a vnode source on Darwin, an inotify read source on Linux.
    // crash-allow: one immutable reference to a dispatch source, whose resume and cancel are safe from any thread (dispatch_source_cancel(3)); Linux's Dispatch module does not mark its source protocols Sendable as Darwin's does
    struct WatchSource: @unchecked Sendable {
        let source: any DispatchSourceProtocol
        func resume() { source.resume() }
        func cancel() { source.cancel() }
    }

    /// The hang-watched lane of `queue` (the server's `control.accept`): each job this watch runs there, a check
    /// or a restore, is one scope of it. Nil watches nothing.
    private let lane: HangWatchedLane?

    init(path: String, queue: DispatchQueue, lane: HangWatchedLane? = nil, yieldsToHeldPath: Bool = false,
         onMissing: @escaping @Sendable () -> Bool) {
        self.path = path
        self.queue = queue
        self.lane = lane
        self.yieldsToHeldPath = yieldsToHeldPath
        self.onMissing = onMissing
    }

    deinit {
        stop()
    }

    func start() {
        stopped.store(false, ordering: .sequentiallyConsistent)
        queue.async { [weak self] in
            guard let self else { return }
            self.job {
                self.watch()
                // Gone before the watch existed: no event will say so.
                var info = stat()
                // SAFETY: lstat reads the NUL-terminated copy of the path made for the call and writes one struct stat into
                // `info`, a local.
                if unsafe lstat(self.path, &info) != 0, errno == ENOENT, self.checkPath() { self.watch() }
            }
        }
    }

    /// One job on `queue`, in one scope of ``lane`` when there is one.
    private func job(_ body: () -> Void) {
        guard let lane else { return body() }
        lane.run(body)
    }

    func stop() {
        retry.cancel()
        // Set before the swap below: a watch() that takes the source lock after it sees it.
        stopped.store(true, ordering: .sequentiallyConsistent)
        source.withLock { watch in
            watch?.cancel()
            watch = nil
        }
    }

    /// Set by ``stop()``: a check in flight on `queue` then watches nothing again.
    private let stopped = Atomic<Bool>(true)

    /// The directory watch is on a shared directory, or the path is held there; logged once per watch.
    private let loggedSharedDirectory = Atomic<Bool>(false)

    /// On `queue`: watches the entry at the path, or its directory when the entry cannot be
    /// opened (a socket file, nothing there); replaces the watch in place. `entryOnly`: keep
    /// the current watch unless the entry can be followed now.
    private func watch(entryOnly: Bool = false) {
        dispatchPrecondition(condition: .onQueue(queue))
        let entryWatch = makeSource(watching: path, followingEntry: true)
        let followsEntry = entryWatch != nil
        if entryOnly, !followsEntry { return }
        let watch: WatchSource
        if let entryWatch {
            watch = entryWatch
        } else {
            let parent = (path as NSString).deletingLastPathComponent
            let shared = Self.isShared(parent.isEmpty ? "." : parent)
            if shared, yieldsToHeldPath, Self.exists(path) {
                // Another entry (a live socket) holds the path: nothing can be made there while it
                // does, and watching /tmp would wake on every write by any process.
                dropWatch()
                noteOnce("socket path watch off for \(self.path): another entry holds the path in \(parent); the link is not made this run")
                return
            }
            guard let directoryWatch = makeSource(watching: parent.isEmpty ? "." : parent, followingEntry: false) else {
                // Without the watch a deleted socket stays gone until relaunch; say so once.
                let error = POSIXErrorText(errno).description
                pathWatchLog.error("socket path watch off: cannot open \(parent, privacy: .public): \(error, privacy: .public)")
                return
            }
            watch = directoryWatch
            if shared { noteOnce("socket path watch on shared directory \(parent) for \(self.path): wakes on every write there") }
        }
        // Resumed before it is published (an inactive source must never be cancelled or
        // released); its events run on `queue`, after this install.
        watch.resume()
        let installed = source.withLock { current -> Bool in
            guard !stopped.load(ordering: .sequentiallyConsistent) else { return false }
            current?.cancel()
            current = watch
            return true
        }
        if !installed { watch.cancel() }
    }

    /// A watch, not yet resumed, whose events run ``changed(followingEntry:)`` on `queue`: of the entry at
    /// `target` itself (`followingEntry`: its deletion, rename or revocation) or of the directory `target`
    /// (an entry made, removed or renamed in it). Nil, with `errno` set, when `target` cannot be watched.
    ///
    /// Darwin: a vnode source on `target` opened with `O_EVTONLY` (`O_SYMLINK`: a link itself, not its
    /// target); a socket cannot be opened, so for one the watch falls back to the directory. Linux: an
    /// inotify watch, which takes any inode by path without opening it, sockets and FIFOs included, so the
    /// entry is followed whatever it is (`IN_DONT_FOLLOW`: a link itself). An unlink is `IN_ATTRIB` (its
    /// link count): a bound socket keeps its inode alive, so `IN_DELETE_SELF` comes only when it closes.
    /// Chromium's Linux file watcher uses inotify the same way (base/files/file_path_watcher_inotify.cc).
    private func makeSource(watching target: String, followingEntry: Bool) -> WatchSource? {
        #if canImport(Darwin)
        // O_NONBLOCK: whatever is at the path is opened, and a FIFO there would block open(2) on this
        // queue until some process opened it for writing (the accept queue: no request answered).
        // SAFETY: open reads the NUL-terminated copy of the path made for the call.
        let descriptor = unsafe open(target, followingEntry ? O_EVTONLY | O_SYMLINK | O_NONBLOCK : O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let mask: DispatchSource.FileSystemEvent = followingEntry ? [.delete, .rename, .revoke] : [.write, .rename, .delete]
        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: mask, queue: queue)
        // wakeup-allow: kqueue event on the entry (or its directory), no timer; one lstat per event
        watch.setEventHandler { [weak self] in
            guard let self else { return }
            self.job { self.changed(followingEntry: followingEntry) }
        }
        #else
        let descriptor = inotify_init1(Int32(truncatingIfNeeded: IN_NONBLOCK | IN_CLOEXEC))
        guard descriptor >= 0 else { return nil }
        let mask = followingEntry
            ? UInt32(truncatingIfNeeded: IN_ATTRIB | IN_DELETE_SELF | IN_MOVE_SELF | IN_DONT_FOLLOW)
            : UInt32(truncatingIfNeeded: IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_DELETE_SELF | IN_MOVE_SELF | IN_ONLYDIR)
        // SAFETY: inotify_add_watch reads the NUL-terminated copy of the path made for the call.
        guard unsafe inotify_add_watch(descriptor, target, mask) >= 0 else {
            let code = errno
            close(descriptor)
            errno = code
            return nil
        }
        let watch = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        // wakeup-allow: inotify event on the entry (or its directory), no timer; one lstat per burst of events
        watch.setEventHandler { [weak self] in
            Self.drainEvents(descriptor)  // the read source is level-triggered
            guard let self else { return }
            self.job { self.changed(followingEntry: followingEntry) }
        }
        #endif
        watch.setCancelHandler { close(descriptor) }
        return WatchSource(source: watch)
    }

    #if !canImport(Darwin)
    /// Reads every queued event off the non-blocking inotify descriptor: one check answers them all.
    private static func drainEvents(_ descriptor: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        // wakeup-allow: bounded: reads until the queue is empty (EAGAIN), no wait
        while true {
            // SAFETY: read writes at most buffer.count bytes into the array's own storage, lent for the call.
            let count = unsafe read(descriptor, &buffer, buffer.count)
            if count > 0 || (count < 0 && errno == EINTR) { continue }
            return
        }
    }
    #endif

    /// On `queue`: cancels the current watch and watches nothing.
    private func dropWatch() {
        source.withLock { current in
            current?.cancel()
            current = nil
        }
    }

    /// An event on `queue`. The entry a watch follows was deleted, renamed or revoked: whatever
    /// is at the path now (put back, or someone else's) is a new file, watched again. A
    /// directory watch moves to the entry whenever one it can follow is there.
    private func changed(followingEntry: Bool) {
        let restored = checkPath()
        if followingEntry || restored {
            watch()
        } else if !stopped.load(ordering: .sequentiallyConsistent), Self.exists(path) {
            // An entry it cannot follow is there now: a yielding watch lets go of the directory.
            watch(entryOnly: !yieldsToHeldPath)
        }
    }

    /// Something (a file, a socket, a link) is at `path`.
    private static func exists(_ path: String) -> Bool {
        var info = stat()
        // SAFETY: lstat reads the NUL-terminated copy of the path made for the call and writes one struct stat into
        // `info`, a local.
        return unsafe lstat(path, &info) == 0
    }

    /// A sticky, world-writable directory (/tmp): every process on the Mac writes there.
    private static func isShared(_ directory: String) -> Bool {
        var info = stat()
        // SAFETY: stat reads the NUL-terminated copy of the path made for the call and writes one struct stat into
        // `info`, a local.
        return unsafe stat(directory, &info) == 0 && info.st_mode & S_ISVTX != 0 && info.st_mode & S_IWOTH != 0
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
        // SAFETY: lstat reads the NUL-terminated copy of the path made for the call and writes one struct stat into
        // `info`, a local.
        guard unsafe lstat(path, &info) != 0, errno == ENOENT, !stopped.load(ordering: .sequentiallyConsistent) else {
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
            queue.async { self.job { if self.checkPath(retrying: true) { self.watch() } } }
        }
        return false
    }
}

private let pathWatchLog = Logger(subsystem: "com.cmuxterm.app.next", category: "control-socket")
