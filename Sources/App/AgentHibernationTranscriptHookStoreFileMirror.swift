import Foundation

struct AgentHibernationTranscriptHookStoreFileMirror: Decodable {
    let sessions: [String: AgentHibernationTranscriptHookStoreRecord]?
}
