import CmuxNextCompat
import CmuxNextWakeups
import Darwin
import Foundation

/// Notices that a control socket's file is gone and asks for it back.
///
/// A host's /tmp cleaner deleted a running app's `/tmp/cmux-debug-<tag>.sock`
/// at the same hour two nights running (readiness soak, hq#1870): the app kept
/// listening on the unlinked inode and no client could connect until a
/// relaunch. This watches the socket's directory with kqueue (no timer), checks
/// the path once a burst of changes settles, and calls `onMissing` only when
/// nothing is at the path. A path that exists is left alone, whoever owns it.
final class ControlSocketPathWatch: Sendable {
    let path: String
    private let queue: DispatchQueue
    private let onMissing: @Sendable () -> Void
    /// Coalesces a burst of directory changes into one check.
    private let check = DemandTimer(owner: "ControlSocketPathWatch.check")
    private let source = Mutex<(any DispatchSourceFileSystemObject)?>(nil)

    init(path: String, queue: DispatchQueue, onMissing: @escaping @Sendable () -> Void) {
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
        watch.setEventHandler { [weak self] in
            self?.check.scheduleIfIdle(after: .milliseconds(250)) { [weak self] in self?.checkPath() }
        }
        watch.setCancelHandler { close(directory) }
        source.withLock { $0 = watch }
        watch.resume()
    }

    func stop() {
        check.cancel()
        source.withLock { watch in
            watch?.cancel()
            watch = nil
        }
    }

    private func checkPath() {
        var info = stat()
        guard lstat(path, &info) != 0, errno == ENOENT, source.withLock({ $0 != nil }) else { return }
        onMissing()
    }
}
