import CmuxNextSignposts
import Darwin
import Foundation

/// Where each launch mark goes out of the process. Always: a launch
/// os_signpost event, and the launch phase intervals it bounds
/// (``LaunchSignposts``, Release too). With `CMUX_NEXT_LAUNCH_MARKS_FD`
/// (inherited from the launcher): also one `<name> <ms>\n` line to that
/// file descriptor, so scripts/cmux-next/bench-startup.py waits on the marks
/// as events instead of polling `debug.timings`. Each line is one `write(2)`
/// under `PIPE_BUF`, so lines from different threads never interleave. The
/// descriptor is nonblocking: a reader that stopped reading loses lines
/// instead of stalling the app. The app drops the variable before any thread
/// starts (`LaunchMarkSink.dropInheritedDescriptor`, CmuxNextApp).
public nonisolated struct LaunchMarkSink: Sendable {
    public static let shared = LaunchMarkSink(environment: ProcessInfo.processInfo.environment)

    public static let environmentKey = "CMUX_NEXT_LAUNCH_MARKS_FD"
    private let fd: Int32?
    private let signposts = LaunchSignposts()

    public init(environment: [String: String]) {
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

    /// Sends the launch mark `name`, `ms` after process start; the caller sends each name once.
    public func write(name: String, ms: Double) {
        signposts.mark(name, ms: ms)
        writeLine("\(name) \(String(format: "%.1f", ms))\n")
    }

    /// Sends the value mark `name` (a count, not a time: bench-startup.py's `VALUE_MARKS`) to the bench's pipe only;
    /// no signpost, which would read it as milliseconds. The caller sends each name once.
    public func writeValue(name: String, value: UInt64) {
        writeLine("\(name) \(value)\n")
    }

    private func writeLine(_ line: String) {
        guard let fd else { return }
        line.utf8CString.withUnsafeBufferPointer { buffer in
            // concurrency-allow: O_NONBLOCK pipe, only when the startup bench passed one; a full pipe drops the line
            _ = Darwin.write(fd, buffer.baseAddress, buffer.count - 1)
        }
    }
}
