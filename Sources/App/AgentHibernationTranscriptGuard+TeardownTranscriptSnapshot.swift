import Foundation

extension AgentHibernationTranscriptGuard {
    struct TeardownTranscriptSnapshot: Sendable {
        let transcriptPath: String
        let snapshotPath: String
        let liveFileVersion: TeardownTranscriptFileVersion?

        init(
            transcriptPath: String,
            snapshotPath: String,
            liveFileVersion: TeardownTranscriptFileVersion? = nil
        ) {
            self.transcriptPath = transcriptPath
            self.snapshotPath = snapshotPath
            self.liveFileVersion = liveFileVersion
        }
    }
}
