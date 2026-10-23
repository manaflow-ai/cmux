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
/// watch falls back to its directory (the quiet per-user state folder). On
/// each event it runs one `lstat` on `queue` and calls `onMissing` only when
/// nothing is at the path; a path that exists is left alone, whoever owns it.
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
    private let source = Mutex<(any DispatchSourceFileSystemObject)?>(nil)
    private let failures = Mutex(Failures())
    /// The retry after ``maxFailedRestores`` failures in a row.
    private let retry = DemandTimer(owner: "ControlSocketPathWatch.retry")
    /// Path checks run so far: each is one wakeup of `queue` (tests count them).
    let checks = Atomic<Int>(0)

    struct Failures {
        var inARow = 0
        var waiting = false
        var backoff = Backoff(initial: .seconds(1), maximum: .seconds(60))
    }

    init(path: String, queue: DispatchQueue, onMissing: @escaping @Sendable () -> Bool) {
        self.path = path
        self.queue = queue
        self.onMissing = onMissing
    }

    deinit {
        stop()
    }

    func start() {
        stopped.withLock { $0 = false }
        watch()
    }

    func stop() {
        retry.cancel()
        stopped.withLock { $0 = true }
        source.withLock { watch in
            watch?.cancel()
            watch = nil
        }
    }

    /// Set by ``stop()``: a check in flight on `queue` then watches nothing again.
    private let stopped = Mutex(true)

    /// Watches the entry at the path, or its directory when the entry cannot be opened (a
    /// socket file, nothing there); replaces the watch in place.
    private func watch() {
        let entry = open(path, O_EVTONLY | O_SYMLINK)
        let followsEntry = entry >= 0
        let descriptor: Int32
        if followsEntry {
            descriptor = entry
        } else {
            let parent = (path as NSString).deletingLastPathComponent
            descriptor = open(parent.isEmpty ? "." : parent, O_EVTONLY)
            guard descriptor >= 0 else {
                // Without the watch a deleted socket stays gone until relaunch; say so once.
                let error = String(cString: strerror(errno))
                pathWatchLog.error("socket path watch off: cannot open \(parent, privacy: .public): \(error, privacy: .public)")
                return
            }
        }
        let mask: DispatchSource.FileSystemEvent = followsEntry ? [.delete, .rename, .revoke] : [.write, .rename, .delete]
        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: mask, queue: queue)
        // wakeup-allow: kqueue event on the entry (or its directory), no timer; one lstat per event
        watch.setEventHandler { [weak self] in self?.changed(followingEntry: followsEntry) }
        watch.setCancelHandler { close(descriptor) }
        // Resumed before it is published: an inactive source must never be cancelled or released.
        watch.resume()
        let installed = stopped.withLock { stopped -> Bool in
            guard !stopped else { return false }
            source.withLock { current in
                current?.cancel()
                current = watch
            }
            return true
        }
        if !installed { watch.cancel() }
    }

    /// An event on `queue`. The entry a watch follows was deleted, renamed or revoked: whatever
    /// is at the path now (put back, or someone else's) is a new file, watched again.
    private func changed(followingEntry: Bool) {
        let restored = checkPath()
        if followingEntry || restored { watch() }
    }

    /// Runs on `queue`, so a restore never overlaps the server's accept handler. True when it
    /// put the path back.
    @discardableResult
    private func checkPath(retrying: Bool = false) -> Bool {
        checks.add(1, ordering: .relaxed)
        if !retrying, failures.withLock({ $0.waiting }) { return false }  // backing off
        var info = stat()
        guard lstat(path, &info) != 0, errno == ENOENT, source.withLock({ $0 != nil }) else {
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
