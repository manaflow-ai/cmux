import CmuxAgentReplica

struct EntryContext: Sendable {
    let entry: EntrySnapshot
    let tick: Int
    let dayKey: String

    var proseRole: TranscriptProseRole? {
        switch entry.content.payload {
        case .userMessage:
            .user
        case .agentProse:
            .agent
        case .thought, .toolRun, .fileChange, .question, .permission, .status, .attachment, .unknown:
            nil
        }
    }
}
