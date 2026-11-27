import Foundation

extension AgentHibernationTranscriptGuard {
    enum TeardownSnapshotOutcome: Sendable {
        case snapshot(TeardownTranscriptSnapshot)
        case nothingToProtect
        case unableToProtect
        /// The transcript shows background work (a background Bash command, a
        /// Monitor, or an async Agent) that has not reported completion.
        case backgroundWorkPending
    }
}
