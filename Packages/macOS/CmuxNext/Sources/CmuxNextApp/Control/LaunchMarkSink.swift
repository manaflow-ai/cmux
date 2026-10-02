import Darwin
import Foundation

/// Streams each launch mark as one `<name> <ms>\n` line to the file
/// descriptor named by `CMUX_NEXT_LAUNCH_MARKS_FD` (inherited from the
/// launcher), so scripts/cmux-next/bench-startup.py waits on the marks as
/// events instead of polling `debug.timings`. Without the variable it does
/// nothing. Each line is one `write(2)` under `PIPE_BUF`, so lines from
/// different threads never interleave.
nonisolated struct LaunchMarkSink: Sendable {
    static let shared = LaunchMarkSink(environment: ProcessInfo.processInfo.environment)

    static let environmentKey = "CMUX_NEXT_LAUNCH_MARKS_FD"
    private let fd: Int32?

    init(environment: [String: String]) {
        guard let text = environment[Self.environmentKey], let fd = Int32(text), fd > 2,
              fcntl(fd, F_GETFD) != -1 else {
            self.fd = nil
            return
        }
        // Never leak the bench's pipe into the daemon or terminals.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        self.fd = fd
    }

    func write(name: String, ms: Double) {
        guard let fd else { return }
        let line = "\(name) \(String(format: "%.1f", ms))\n"
        line.utf8CString.withUnsafeBufferPointer { buffer in
            _ = Darwin.write(fd, buffer.baseAddress, buffer.count - 1)
        }
    }
}
