import CmuxHomeCore
import Foundation

/// A user turn waiting for its conversation's running turn to end.
struct ChiefPendingTurn: Sendable {
    /// The user message's seq; the Chief's read cursor moves there when the turn starts.
    var readSeq: Seq?
    var text: String
    var attachmentPaths: [URL]
    var replyContext: String?
    /// The thread the user wrote in; the Chief answers in the same thread.
    var threadRoot: MessageID?
}

/// Where an approval card is: its message and the approval part's index.
/// Answers address a card by its place, never by the brain's request id alone.
struct ChiefApprovalSlot: Hashable, Sendable {
    var message: MessageID
    var part: Int
}

/// The running turn of one conversation.
struct ChiefRunningTurn {
    let id = UUID()
    let chief: ParticipantID
    let threadRoot: MessageID?
    var task: Task<Void, Never>?
    /// The draft turn key of the current text segment; the segment's message commits under it.
    var segmentKey: IdempotencyKey?
    var segmentText = ""
    var segment: UInt64 = 0
    /// Draft item seq, one per update across the whole turn.
    var draftSeq: UInt64 = 0
    /// Work messages still running, by the brain's tool call id.
    var tools: [String: MessageID] = [:]
    /// Approval cards waiting for the user, with the brain's own request id of each.
    /// While any waits the Chief is not typing (it waits for the user,
    /// ``ChiefConversationOwner/answerApproval(conversation:message:part:choice:)``).
    var approvals: [ChiefApprovalSlot: String] = [:]
    /// The running tool row a waiting card took the place of (its call id and work part): allowed,
    /// the row comes back under the card's receipt, so Home draws one "Ran … · Allowed" row.
    var approvedWork: [ChiefApprovalSlot: (tool: String, work: WorkRef)] = [:]
    /// The turn's one Cloud provisioning row (``ChiefCloudProvisioning``), once a provisioning call started.
    var provisioning: MessageID?
    /// The provisioning step of each running provisioning call, by tool call id.
    var provisioningCalls: [String: ChiefCloudProvisioning] = [:]
    /// The provisioning row's status so far.
    var provisioningStatus: WorkRef.Status = .running
    /// When the turn started, for its ``ChiefTurnStats``.
    let startedAt: Date
    /// The engine from the turn's context, once it is built.
    var engine: ChiefTurnEngine?
    var toolCalls = 0
    var failedToolCalls = 0
    /// Memory notes saved during the turn (``ChiefConversationOwner/noteMemorySaved(conversation:fact:text:)``):
    /// their rows post after the turn's last message.
    var memoryNotes: [(fact: String, text: String)] = []
    var usage: ChiefTurnUsage?

    /// The request id a card of this turn stores for the brain's `id`. Brains
    /// reuse ids across processes (Codex numbers its requests from 0 per
    /// app-server process), so the card's id carries this turn's namespace:
    /// no card of another turn or run can ever name this turn's request.
    func cardRequestID(_ request: String) -> String {
        let namespace = id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
        return "t\(namespace):\(request)"
    }

    init(chief: ParticipantID, threadRoot: MessageID?, startedAt: Date = Date()) {
        self.chief = chief
        self.threadRoot = threadRoot
        self.startedAt = startedAt
    }
}
