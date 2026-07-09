import Foundation

extension AgentHibernationTranscriptGuard {
    struct TeardownTranscriptSnapshot: Sendable {
        let transcriptPath: String
        let snapshotPath: String
    }
}
