import Darwin
import Foundation

struct PaneMemoryProcessKiller {
    /// SIGTERM the pane's high-memory process group(s) now, then SIGKILL after a
    /// short grace. Negative pid targets the whole process group, so the runaway
    /// job and its descendants die without signaling unrelated groups in the
    /// same pane. The delayed escalation revalidates against a fresh process
    /// snapshot so stale or reused process-group IDs are not force-killed.
    /// ESRCH on an already-dead group is harmless.
    func terminate(
        processGroupIDs: [Int],
        graceSeconds: TimeInterval = 3,
        validateBeforeSIGKILL: @escaping @Sendable () -> Set<Int>
    ) -> Task<Void, Never>? {
        let pgids = processGroupIDs.filter { $0 > 1 }
        guard !pgids.isEmpty else { return nil }
        for pgid in pgids {
            _ = kill(pid_t(-pgid), SIGTERM)
        }
        let delayNanoseconds = UInt64(max(0, graceSeconds) * 1_000_000_000)
        return Task.detached(priority: .userInitiated) { [pgids] in
            // Bounded SIGTERM grace period before escalation; cancellation suppresses SIGKILL.
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            let validatedPGIDs = validateBeforeSIGKILL()
            for pgid in pgids where validatedPGIDs.contains(pgid) {
                _ = kill(pid_t(-pgid), SIGKILL)
            }
        }
    }
}
