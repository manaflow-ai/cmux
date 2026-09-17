import Foundation

extension AgentHibernationTranscriptGuard {
    enum TeardownSnapshotOutcome: Sendable {
        case snapshot(TeardownTranscriptSnapshot)
        case nothingToProtect
        case unableToProtect
    }
}
