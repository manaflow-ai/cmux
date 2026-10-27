import CmuxNextWakeups
import Foundation

/// A page call that answers by a deadline, also when its work never ends: the first of the work's
/// end, the deadline and the caller's cancel answers (once). The race is the ``Deadline`` helper
/// (R-timer's race recipe, plans/cmux-next/chrome-parity/p06-scheduler.md) on the injected clock, so a
/// test moves time without waiting. The work is cancelled when the deadline or the caller's cancel
/// answers; a late result is dropped.
@MainActor
enum PageCallDeadline {
    static func answer<T: Sendable>(within deadline: Duration, clock: any Clock<Duration>,
                                    onTimeout: @escaping @MainActor @Sendable () -> any Error,
                                    _ work: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
        // Cancelled before it started: no work runs.
        try Task.checkCancellation()
        do {
            return try await Deadline(deadline, clock: clock).run("PageCallDeadline") { try await work() }
        } catch is Deadline.Exceeded {
            throw onTimeout()
        }
    }
}
