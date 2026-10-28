import Darwin
import Foundation
import CmuxNextCompat
import CmuxNextWakeups

/// The acpmux daemon's start progress, read from its log: a daemon that still writes its log is
/// still starting (it loads chats, adopts agents, reads the login environment). The launch waits
/// for its ready line as long as the log moves, and gives up only after a whole stall time with no
/// write (2026-10-20: a fixed 20 s cut off starts that took 19 to 28 s over 3.9 GB of chats).
nonisolated final class AcpmuxLogProgress: Sendable {
    // Written by the file source's handler, read by the waiting task: a tiny timestamp, the
    // lock carve-out (an actor would add hops to a one-value compare).
    private let lastWrite = Mutex(ContinuousClock.now)
    // DispatchSource file watching has no async equivalent; it lives and dies with this object.
    private nonisolated(unsafe) let source: (any DispatchSourceFileSystemObject)? // crash-allow: an immutable let set once in init; a dispatch source is a thread-safe libdispatch object (handlers, resume, cancel from any thread)

    /// Watches `logPath` (created when missing) for writes from now on.
    init(logPath: String) {
        // SAFETY: open reads the NUL-terminated copy of the path made for the call.
        let fd = unsafe blockingOpen(logPath, O_EVTONLY | O_CREAT, 0o600)
        guard fd >= 0 else {
            source = nil
            return
        }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend],
            queue: DispatchQueue(label: "cmux.next.agent-pane.acpmux-log-progress", qos: .utility))
        source?.setEventHandler { [weak self] in self?.lastWrite.withLock { $0 = ContinuousClock.now } }
        source?.setCancelHandler { close(fd) }
        source?.resume()
    }

    deinit { source?.cancel() }

    /// Returns once the log has had no write for `stall`. Cancellable. The stall is a flexible,
    /// no-sooner deadline: it sleeps with ``WakeLeeway``'s tolerance for `stall`.
    func stalled(for stall: Duration) async throws {
        let tolerance = WakeLeeway.window(delay: stall).tolerance
        var due = lastWrite.withLock { $0 } + stall
        while ContinuousClock.now < due {
            // wakeup-allow: deadline the stall deadline itself; it wakes again only when a log write moved it.
            // timer-class-allow: off main (this Sendable class's wait runs in the launcher's task group): a flexible,
            // no-sooner deadline that wakes no main-thread job; it re-arms only after a log write moved it
            try await ContinuousClock().sleep(until: due, tolerance: tolerance)
            due = lastWrite.withLock { $0 } + stall
        }
    }
}
