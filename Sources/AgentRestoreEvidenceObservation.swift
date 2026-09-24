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
        if let process, AgentPIDProcessIdentity(pid: process.pid) != process { return }
        let observation = AgentRestoreEvidenceSubscription(process: process, paths: paths)
        defer { observation.cancel() }
        // Close the registration race without ever accepting a reused PID.
        if let process, AgentPIDProcessIdentity(pid: process.pid) != process { return }
        for await _ in observation.events { return }
    }
}
