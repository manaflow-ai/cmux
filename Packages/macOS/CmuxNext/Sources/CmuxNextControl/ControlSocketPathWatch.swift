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
/// whatever is at the path then. A held path with no listener to follow keeps
/// the directory watch, logged once: a stale socket of another user (which
/// nothing here may remove), a socket that names no pid, or one whose pid is
/// not a live process. `LOCAL_PEERPID` reports the socket's last user, not a
/// guaranteed listener: that process may have exited while one that inherited
/// the descriptor keeps the socket accepting. A pid whose exit the watch has
/// already handled is never followed again, so a live socket that keeps
/// naming it settles on the directory watch instead of following it in a loop.
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
    /// Follow the listener of a foreign live socket that holds the path in a shared directory,
    /// not the directory.
    private let yieldsToHeldPath: Bool
    // Lock carve-out: stop() runs off `queue` and must cancel the installed watch synchronously
    // (deinit); held only to swap one reference. A file system source, or the process source of a
    // holder's listener.
    private let source = Mutex<(any DispatchSourceProtocol)?>(nil)
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

    init(path: String, queue: DispatchQueue, yieldsToHeldPath: Bool = false, onMissing: @escaping @Sendable () -> Bool) {
        self.path = path
        self.queue = queue
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
            self.watch()
            // Gone before the watch existed: no event will say so.
            var info = stat()
            if lstat(self.path, &info) != 0, errno == ENOENT, self.checkPath() { self.watch() }
        }
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

    /// The last holder pid whose exit ``holderEnded(_:)`` handled (0: none). A socket that still
    /// names it after that exit is held by some other process the pid does not identify.
    private let endedListener = Atomic<pid_t>(0)
    // Lock carve-out: read and written only on `queue` (watch and changed); a two-field value
    // swapped under the lock, never held across a call out.
    /// The live socket file at the path whose pid identifies no holder: while the same file is
    /// there, a directory event does not probe (connect to) it again.
    private let unfollowable = Mutex<FileIdentity?>(nil)

    /// A file's device and inode.
    struct FileIdentity: Equatable {
        var device: dev_t
        var inode: ino_t
    }

    /// On `queue`: watches the entry at the path, or its directory when the entry cannot be
    /// opened (a socket file, nothing there), or for a yielding watch the listener of a live
    /// socket that holds the path; replaces the watch in place. `entryOnly`: keep the current
    /// watch unless the entry can be followed now.
    private func watch(entryOnly: Bool = false) {
        dispatchPrecondition(condition: .onQueue(queue))
        let entry = open(path, O_EVTONLY | O_SYMLINK)
        let followsEntry = entry >= 0
        if entryOnly, !followsEntry { return }
        // Set again below only when the path still holds a socket whose pid names no holder.
        unfollowable.withLock { $0 = nil }
        let descriptor: Int32
        if followsEntry {
            descriptor = entry
        } else {
            let parent = (path as NSString).deletingLastPathComponent
            let shared = Self.isShared(parent.isEmpty ? "." : parent)
            if shared, yieldsToHeldPath, Self.exists(path),
               case .accepted(let listener?) = ControlSocketServer.probe(path) {
                // Another app's live socket holds the path: nothing can be made there until its
                // listener ends, and watching /tmp would wake on every write by any process.
                if watchHolder(listener, parent: parent) { return }
                // Its pid names no holder: the directory watch below, without a probe per event.
                unfollowable.withLock { $0 = Self.identity(path) }
            }
            descriptor = open(parent.isEmpty ? "." : parent, O_EVTONLY)
            guard descriptor >= 0 else {
                // Without the watch a deleted socket stays gone until relaunch; say so once.
                let error = String(cString: strerror(errno))
                pathWatchLog.error("socket path watch off: cannot open \(parent, privacy: .public): \(error, privacy: .public)")
                return
            }
            if shared { noteOnce("socket path watch on shared directory \(parent) for \(self.path): wakes on every write there") }
        }
        let mask: DispatchSource.FileSystemEvent = followsEntry ? [.delete, .rename, .revoke] : [.write, .rename, .delete]
        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: mask, queue: queue)
        // wakeup-allow: kqueue event on the entry (or its directory), no timer; one lstat per event
        watch.setEventHandler { [weak self] in self?.changed(followingEntry: followsEntry) }
        watch.setCancelHandler { close(descriptor) }
        install(watch)
    }

    /// On `queue`: follows the process `listener`, whose live socket holds the path; its exit
    /// is the one event that can free the path. False, with nothing installed, when the pid
    /// identifies no holder to follow: it is not a live process, or its exit was already handled
    /// while the socket still accepts (a process that inherited the descriptor holds it). The
    /// caller then keeps the directory watch. Never calls ``watch(entryOnly:)`` itself.
    private func watchHolder(_ listener: pid_t, parent: String) -> Bool {
        guard listener != endedListener.load(ordering: .relaxed), Self.isLive(listener) else { return false }
        let watch = DispatchSource.makeProcessSource(identifier: listener, eventMask: .exit, queue: queue)
        // wakeup-allow: one kevent when the holder's listener exits, no timer
        watch.setEventHandler { [weak self] in self?.holderEnded(listener) }
        guard install(watch) else { return true }  // stopped: watches nothing, by design
        noteOnce("socket path watch for \(path) follows pid \(listener), whose live socket holds the path in \(parent); the link is made when it ends")
        // Ended between the check above and the arming: no event may say so. holderEnded's
        // watch() never follows this pid again, so this runs at most once per pid.
        if !Self.isLive(listener) { holderEnded(listener) }
        return true
    }

    /// `pid` is a process that exists (`kill(pid, 0)` succeeds, or is refused for another
    /// user's process).
    private static func isLive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// On `queue`: resumes `watch` and makes it the installed one, cancelling the one before;
    /// false (and `watch` cancelled) once stopped.
    @discardableResult
    private func install(_ watch: any DispatchSourceProtocol) -> Bool {
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
        return installed
    }

    /// On `queue`: the listener `listener`, whose socket held the path, ended. Its socket file is
    /// gone, or left behind stale: either way the restore takes the path now (the link's
    /// replaces a stale socket of this user and leaves anything else), then the watch follows
    /// whatever is at the path. A socket there that still names `listener` is not followed
    /// again (``watchHolder(_:parent:)``), so this never re-enters itself.
    private func holderEnded(_ listener: pid_t) {
        guard !stopped.load(ordering: .sequentiallyConsistent) else { return }
        endedListener.store(listener, ordering: .relaxed)
        if Self.exists(path) {
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
    /// directory watch moves to the entry whenever one it can follow is there.
    private func changed(followingEntry: Bool) {
        let restored = checkPath()
        if followingEntry || restored {
            watch()
        } else if !stopped.load(ordering: .sequentiallyConsistent), let identity = Self.identity(path) {
            // The same live socket whose pid names no holder: the directory watch stays, no probe.
            if yieldsToHeldPath, unfollowable.withLock({ $0 }) == identity { return }
            // An entry it cannot follow is there now: a yielding watch moves to its listener.
            watch(entryOnly: !yieldsToHeldPath)
        }
    }

    /// The device and inode of what is at `path` (not following a link), nil for nothing.
    private static func identity(_ path: String) -> FileIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    /// Something (a file, a socket, a link) is at `path`.
    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
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
