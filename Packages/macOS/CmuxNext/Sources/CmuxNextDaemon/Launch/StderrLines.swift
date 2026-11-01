import CmuxNextCompat
import Darwin
import Dispatch

/// Hands a child's stderr to `onLine` line by line as the child writes it (`ProcessRunner.run(stderrLine:)`).
/// The child writes to an unlinked temp file, not a pipe (``ProcessRunner``); this watches that file
/// for writes (a vnode source on its own duplicate of the descriptor) and reads what was appended
/// with `pread`, so nothing here can block the child or be held open by a grandchild.
///
/// Stop condition: the runner calls ``finish()`` once the child has exited (or ``cancel()`` when it
/// throws), which reads the file to its end, delivers the last line, and cancels the source. The
/// cancel handler closes the duplicate descriptor; nothing is read after that.
final class StderrLines: Sendable {
    private struct State {
        var offset: off_t = 0
        var pending: [UInt8] = []
        var done = false
    }

    /// Longest line kept; a longer one is cut there (progress lines are short).
    static let maxLine = 64 * 1024

    private let fd: Int32
    private let onLine: @Sendable (String) -> Void
    private let state = Mutex(State())
    private let source = Mutex<(any DispatchSourceFileSystemObject)?>(nil)
    private let queue = DispatchQueue(label: "com.cmuxterm.next.process-stderr")

    init(watching fd: Int32, onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
        self.fd = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard self.fd >= 0 else { return }
        let watched = self.fd
        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: watched, eventMask: [.write, .extend], queue: queue)
        watch.setEventHandler { [weak self] in self?.drain(final: false) }
        watch.setCancelHandler { close(watched) }
        watch.activate()
        source.withLock { $0 = watch }
    }

    /// The child exited: the rest of the file, its last line too, then the watch stops.
    func finish() {
        queue.sync { drain(final: true) }
        cancel()
    }

    func cancel() {
        source.withLock { source in
            source?.cancel()
            source = nil
        }
    }

    /// Reads what was appended since the last read (on `queue`) and hands over each whole line;
    /// `final` also hands over a last line with no newline.
    private func drain(final: Bool) {
        guard fd >= 0 else { return }
        var lines: [String] = []
        state.withLock { state in
            guard !state.done else { return }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            // A regular file: each read returns what is there and 0 at its end (or -1 on an error),
            // so the loop ends at EOF and on any error.
            var count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, state.offset) }
            while count > 0 {
                state.offset += off_t(count)
                for byte in buffer.prefix(count) {
                    if byte == UInt8(ascii: "\n") {
                        lines.append(String(decoding: state.pending, as: UTF8.self))
                        state.pending.removeAll(keepingCapacity: true)
                    } else if state.pending.count < Self.maxLine {
                        state.pending.append(byte)
                    }
                }
                count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, state.offset) }
            }
            if final {
                if !state.pending.isEmpty { lines.append(String(decoding: state.pending, as: UTF8.self)) }
                state.pending.removeAll()
                state.done = true
            }
        }
        for line in lines { onLine(line) }
    }
}
