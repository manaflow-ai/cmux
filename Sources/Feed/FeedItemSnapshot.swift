import CMUXAgentLaunch
import Foundation

struct FeedItemSnapshot: Equatable {
    let id: UUID
    let workstreamId: String
    let source: WorkstreamSource
    let kind: WorkstreamKind
    let title: String?
    let cwd: String?
    let createdAt: Date
    let status: WorkstreamStatus
    let payload: WorkstreamPayload
    let requestID: String?
    let context: WorkstreamContext?
    /// Most recent user-prompt text in the same workstream, attached
    /// by the list view so every card can show a "You: …" echo for
    /// context, even when the agent payload doesn't carry it directly.
    let userPromptEcho: String?

    init(item: WorkstreamItem, userPromptEcho: String? = nil) {
        self.id = item.id
        self.workstreamId = item.workstreamId
        self.source = item.source
        self.kind = item.kind
        self.title = item.title
        self.cwd = item.cwd
        self.createdAt = item.createdAt
        self.status = item.status
        self.payload = item.payload
        switch item.payload {
        case .permissionRequest(let requestID, _, _, _),
             .exitPlan(let requestID, _, _),
             .question(let requestID, _):
            self.requestID = requestID
        default:
            self.requestID = nil
        }
        self.context = item.context
        self.userPromptEcho = userPromptEcho
    }
}
