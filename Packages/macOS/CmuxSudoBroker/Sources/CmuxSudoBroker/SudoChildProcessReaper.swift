import Darwin
import Foundation

/// Reaps one direct child on a dedicated detached POSIX thread.
///
/// `waitpid` is intentionally kept off Swift's cooperative executor. The
/// hidden runner can outlive the app, while a still-running app remains the
/// child's only legal reaper and must not accumulate zombies.
struct SudoChildProcessReaper: Sendable {
    /// Starts reaping and emits the child PID exactly once when `waitpid` returns.
    func start(processIdentifier: Int32) -> AsyncStream<Int32> {
        let pair = AsyncStream.makeStream(
            of: Int32.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        guard processIdentifier > 1 else {
            pair.continuation.finish()
            return pair.stream
        }
        Thread.detachNewThread {
            var status: Int32 = 0
            var result: pid_t = 0
            repeat {
                result = waitpid(processIdentifier, &status, 0)
            } while result < 0 && errno == EINTR
            pair.continuation.yield(processIdentifier)
            pair.continuation.finish()
        }
        return pair.stream
    }
}
