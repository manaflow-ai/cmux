import CmuxNextCompat
import Darwin
import Foundation

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
/// row the watch stops. Deleting or renaming the directory itself is not
/// followed: the directory is /tmp or the per-user state folder.
final class ControlSocketPathWatch: Sendable {
    static let maxFailedRestores = 3

    let path: String
    private let queue: DispatchQueue
    private let onMissing: @Sendable () -> Bool
    private let source = Mutex<(any DispatchSourceFileSystemObject)?>(nil)
    private let failedRestores = Mutex(0)

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
        guard directory >= 0 else { return }
        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: directory, eventMask: [.write, .rename, .delete], queue: queue)
        // wakeup-allow: kqueue directory event (no timer); one lstat per event
        watch.setEventHandler { [weak self] in self?.checkPath() }
        watch.setCancelHandler { close(directory) }
        source.withLock { $0 = watch }
        watch.resume()
    }

    func stop() {
        source.withLock { watch in
            watch?.cancel()
            watch = nil
        }
    }

    /// Runs on `queue`, so a restore never overlaps the server's accept handler.
    private func checkPath() {
        var info = stat()
        guard lstat(path, &info) != 0, errno == ENOENT, source.withLock({ $0 != nil }) else { return }
        if onMissing() {
            failedRestores.withLock { $0 = 0 }
            return
        }
        let failures = failedRestores.withLock { count -> Int in
            count += 1
            return count
        }
        if failures >= Self.maxFailedRestores { stop() }
    }
}
