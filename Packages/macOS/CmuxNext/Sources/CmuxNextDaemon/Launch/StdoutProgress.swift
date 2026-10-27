import CmuxNextCompat
import Darwin
import Dispatch

/// The time of the last write to a child's stdout file (`ProcessRunner.run(progressIdle:)`).
/// The watch has its own duplicate of the descriptor, closed by the cancel
/// handler, so the caller may close its file at any time.
final class StdoutProgress: Sendable {
    /// The time since the run started, on the run's clock.
    let elapsed: @Sendable () -> Duration
    /// When the last write came, on ``elapsed``; nil before the first.
    private let last = Mutex<Duration?>(nil)
    private let source = Mutex<(any DispatchSourceFileSystemObject)?>(nil)
    private let queue = DispatchQueue(label: "com.cmuxterm.next.process-progress", qos: .utility)

    /// No watch: the caller reports each write with ``noteWrite()`` (tests).
    init(elapsed: @escaping @Sendable () -> Duration) {
        self.elapsed = elapsed
    }

    convenience init(watching fd: Int32, elapsed: @escaping @Sendable () -> Duration) {
        self.init(elapsed: elapsed)
        let watched = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard watched >= 0 else { return }
        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: watched, eventMask: [.write, .extend],
                                                              queue: queue)
        watch.setEventHandler { [weak self] in self?.noteWrite() }
        watch.setCancelHandler { close(watched) }
        watch.activate()
        source.withLock { $0 = watch }
    }

    /// One write to the child's stdout, now.
    func noteWrite() {
        let now = elapsed()
        last.withLock { $0 = now }
    }

    var lastWrite: Duration? { last.withLock { $0 } }

    func cancel() { source.withLock { $0?.cancel() } }
}
