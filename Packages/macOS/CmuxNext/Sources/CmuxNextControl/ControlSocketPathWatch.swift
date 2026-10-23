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
/// relaunch. This watches the socket's directory with kqueue (no timer). On
/// each change it runs one `lstat` on `queue` and calls `onMissing` only when
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
        let parent = (path as NSString).deletingLastPathComponent
        let directory = open(parent.isEmpty ? "." : parent, O_EVTONLY)
        guard directory >= 0 else {
            // Without the watch a deleted socket stays gone until relaunch; say so once.
            let error = String(cString: strerror(errno))
            pathWatchLog.error("socket path watch off: cannot open \(parent, privacy: .public): \(error, privacy: .public)")
            return
        }
        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: directory, eventMask: [.write, .rename, .delete], queue: queue)
        // wakeup-allow: kqueue directory event (no timer); one lstat per event
        watch.setEventHandler { [weak self] in self?.checkPath() }
        watch.setCancelHandler { close(directory) }
        source.withLock { $0 = watch }
        watch.resume()
    }

    func stop() {
        retry.cancel()
        source.withLock { watch in
            watch?.cancel()
            watch = nil
        }
    }

    /// Runs on `queue`, so a restore never overlaps the server's accept handler.
    private func checkPath(retrying: Bool = false) {
        checks.add(1, ordering: .relaxed)
        if !retrying, failures.withLock({ $0.waiting }) { return }  // backing off
        var info = stat()
        guard lstat(path, &info) != 0, errno == ENOENT, source.withLock({ $0 != nil }) else {
            failures.withLock { $0 = Failures() }
            return
        }
        if onMissing() {
            failures.withLock { $0 = Failures() }
            return
        }
        let delay = failures.withLock { state -> Duration? in
            state.inARow += 1
            guard state.inARow >= Self.maxFailedRestores else { return nil }
            state.waiting = true
            return state.backoff.next()
        }
        guard let delay else { return }
        let queue = self.queue
        retry.schedule(after: delay) { [weak self] in
            guard let self else { return }
            queue.async { self.checkPath(retrying: true) }
        }
    }
}

private let pathWatchLog = Logger(subsystem: "com.cmuxterm.app.next", category: "control-socket")
