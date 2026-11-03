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
    private let source = Mutex<(any DispatchSourceFileSystemObject)?>(nil)
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

    /// On `queue`: watches the entry at the path, or its directory when the entry cannot be
    /// opened (a socket file, nothing there); replaces the watch in place. `entryOnly`: keep
    /// the current watch unless the entry can be followed now.
    private func watch(entryOnly: Bool = false) {
        dispatchPrecondition(condition: .onQueue(queue))
        // O_NONBLOCK: whatever is at the path is opened, and a FIFO there would block open(2) on this
        // queue until some process opened it for writing (the accept queue: no request answered).
        let entry = open(path, O_EVTONLY | O_SYMLINK | O_NONBLOCK)
        let followsEntry = entry >= 0
        if entryOnly, !followsEntry { return }
        let descriptor: Int32
        if followsEntry {
            descriptor = entry
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
