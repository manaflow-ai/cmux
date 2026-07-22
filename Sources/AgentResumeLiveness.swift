import Foundation

/// Answers "is there already a live process for this agent session?" using
/// the process-liveness facts `SharedLiveAgentIndex` / `RestorableAgentSessionIndex`
/// already maintain. Centralizing the check here means both the launch-time
/// resume gate (`Workspace.createPanel`) and the persist-time stale-binding
/// reconciliation (`Workspace.reconcileSurfaceResumeBindings`) agree on the
/// same definition of "live" (#8446).
enum AgentResumeLiveness {
    /// True when `entry` reports a live process for the same agent session
    /// (matched by kind + session id), i.e. resuming it again would spawn a
    /// duplicate process against the same on-disk session data.
    static func hasLiveProcess(
        for entry: RestorableAgentSessionIndex.Entry?,
        kind: String,
        sessionId: String
    ) -> Bool {
        guard let entry, !entry.processIDs.isEmpty else { return false }
        return entry.snapshot.kind.rawValue == kind && entry.snapshot.sessionId == sessionId
    }
}
