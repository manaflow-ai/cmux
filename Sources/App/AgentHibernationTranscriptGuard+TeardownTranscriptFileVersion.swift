import Foundation

extension AgentHibernationTranscriptGuard {
    struct TeardownTranscriptFileVersion: Equatable, Sendable {
        let fileNumber: UInt64
        let size: UInt64
        let modificationDate: Date
    }
}
