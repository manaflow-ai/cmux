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
    /// Approval messages waiting for the user, by request id. While any waits the Chief
    /// is not typing (it waits for the user, ``ChiefConversationOwner/answerApproval``).
    var approvals: [String: MessageID] = [:]
    /// The turn's one Cloud provisioning row (``ChiefCloudProvisioning``), once a provisioning call started.
    var provisioning: MessageID?
    /// The provisioning step of each running provisioning call, by tool call id.
    var provisioningCalls: [String: ChiefCloudProvisioning.Phase] = [:]
    /// The provisioning row's status so far.
    var provisioningStatus: WorkRef.Status = .running
    /// When the turn started, for its ``ChiefTurnStats``.
    let startedAt: Date
    /// The engine from the turn's context, once it is built.
    var engine: ChiefTurnEngine?
    var toolCalls = 0
    var failedToolCalls = 0
    var usage: ChiefTurnUsage?

    init(chief: ParticipantID, threadRoot: MessageID?, startedAt: Date = Date()) {
        self.chief = chief
        self.threadRoot = threadRoot
        self.startedAt = startedAt
    }
}
