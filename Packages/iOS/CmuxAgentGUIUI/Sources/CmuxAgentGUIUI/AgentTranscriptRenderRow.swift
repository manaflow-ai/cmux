import CmuxAgentChat
import CmuxAgentReplica

struct AgentTranscriptRenderRow: Identifiable, Equatable {
    let id: String
    let content: Content

    enum Content: Equatable {
        case message(ChatMessageRowSnapshot)
        case activity(TranscriptActivityDetails)
        case ask(PendingAsk)
        case metadata(String)
        case pendingTicket(SendTicket)
        case empty(TranscriptSyncPresentation)
    }
}
