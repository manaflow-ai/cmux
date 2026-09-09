import Foundation

/// Stores one queued prompt and its injected main-actor delivery operation.
struct AgentPromptSubmissionPendingRequest {
    let messageID: UUID
    let workspaceID: UUID
    let surfaceID: UUID?
    let text: String
    let delivery: AgentPromptSubmissionService.Delivery

    init(
        messageID: UUID,
        workspaceID: UUID,
        surfaceID: UUID?,
        text: String,
        delivery: @escaping AgentPromptSubmissionService.Delivery
    ) {
        self.messageID = messageID
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.text = text
        self.delivery = delivery
    }
}
