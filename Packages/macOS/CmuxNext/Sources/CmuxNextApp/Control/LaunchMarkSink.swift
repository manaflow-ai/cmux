import Darwin
import Foundation

/// Streams each launch mark as one `<name> <ms>\n` line to the file
/// descriptor named by `CMUX_NEXT_LAUNCH_MARKS_FD` (inherited from the
/// launcher), so scripts/cmux-next/bench-startup.py waits on the marks as
/// events instead of polling `debug.timings`. Without the variable it does
/// nothing. Each line is one `write(2)` under `PIPE_BUF`, so lines from
/// different threads never interleave. The descriptor is nonblocking: a
/// reader that stopped reading loses lines instead of stalling the app.
nonisolated struct LaunchMarkSink: Sendable {
    static let shared = LaunchMarkSink(environment: ProcessInfo.processInfo.environment)

    static let environmentKey = "CMUX_NEXT_LAUNCH_MARKS_FD"
    private let fd: Int32?

    init(environment: [String: String]) {
        // Children (the daemon, terminals) must not inherit the variable:
        // its descriptor number means nothing to them.
        unsetenv(Self.environmentKey)
        guard let text = environment[Self.environmentKey], let fd = Int32(text), fd > 2,
              fcntl(fd, F_GETFD) != -1 else {
            self.fd = nil
            return
        }
        // Never leak the bench's pipe into the daemon or terminals, and
        // never block a caller (the main thread) on a full pipe.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        self.fd = fd
    }

    func write(name: String, ms: Double) {
        guard let fd else { return }
        let line = "\(name) \(String(format: "%.1f", ms))\n"
        line.utf8CString.withUnsafeBufferPointer { buffer in
            // concurrency-allow: O_NONBLOCK pipe, only when the startup bench passed one; a full pipe drops the line
            _ = Darwin.write(fd, buffer.baseAddress, buffer.count - 1)
        }
    }
}
