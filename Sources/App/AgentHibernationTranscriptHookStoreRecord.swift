import Foundation

struct AgentHibernationTranscriptHookStoreRecord: Decodable {
    let sessionId: String?
    let transcriptPath: String?
}
