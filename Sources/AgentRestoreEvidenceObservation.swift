import CmuxFoundation
import Foundation

/// Bridges kernel process/file events into a bounded ownership observation.
struct AgentRestoreEvidenceObservation: Sendable {
    /// A deadline bounds each RPC; it does not end the restore operation.
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated func wait(process: AgentPIDProcessIdentity?, paths: [String]) async {
        await wait(processes: process.map { [$0] } ?? [], paths: paths)
    }

    /// Waits for any supplied process generation or watched path to change.
    /// Every PID is checked before and after registration so a reused PID can
    /// never make a stale owner look live.
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated func wait(
        processes: [AgentPIDProcessIdentity],
        paths: [String]
    ) async {
        guard processes.allSatisfy({ AgentPIDProcessIdentity(pid: $0.pid) == $0 }) else { return }
        let observation = AgentRestoreEvidenceSubscription(processes: processes, paths: paths)
        defer { observation.cancel() }
        // Close the registration race without ever accepting a reused PID.
        guard processes.allSatisfy({ AgentPIDProcessIdentity(pid: $0.pid) == $0 }) else { return }
        for await _ in observation.events { return }
    }
}
