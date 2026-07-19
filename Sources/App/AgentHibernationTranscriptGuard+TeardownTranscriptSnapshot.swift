import Foundation

extension AgentHibernationTranscriptGuard {
    struct TeardownTranscriptSnapshot: Sendable {
        let transcriptPath: String
        let snapshotPath: String
        let liveFileVersion: TeardownTranscriptFileVersion?
        let guardedProcessIdentities: [AgentPIDProcessIdentity]
        let hasUncapturedGuardedProcesses: Bool

        init(
            transcriptPath: String,
            snapshotPath: String,
            liveFileVersion: TeardownTranscriptFileVersion? = nil,
            guardedProcessIdentities: [AgentPIDProcessIdentity] = [],
            hasUncapturedGuardedProcesses: Bool = false
        ) {
            self.transcriptPath = transcriptPath
            self.snapshotPath = snapshotPath
            self.liveFileVersion = liveFileVersion
            self.guardedProcessIdentities = guardedProcessIdentities
            self.hasUncapturedGuardedProcesses = hasUncapturedGuardedProcesses
        }
    }
}
