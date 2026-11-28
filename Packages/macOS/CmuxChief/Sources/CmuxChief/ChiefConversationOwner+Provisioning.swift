import CmuxHomeCore
import Foundation

// A `vm new` that waits for the user's approval: its card takes the provisioning row's place.
extension ChiefConversationOwner {
    /// The turn's provisioning row when the approval `prompt` asks about the `vm new` that just
    /// posted it: the row's only call, still creating, no machine yet.
    ///
    /// The card replaces the row like any tool row awaiting approval (``ChiefRunningTurn/approvedWork``),
    /// so no "Creating cloud machine… 30s" counts while the card waits. An Allow posts the row
    /// again right under the receipt, its `createdAt` (where Home's elapsed time starts) the
    /// moment the command really runs; a Deny leaves only the receipt.
    ///
    /// - Returns: The call id, the row's message and its work part; nil when the card asks about
    ///   something else or the row already showed progress (a `vm wait` after the create).
    func provisioningAwaitingApproval(_ prompt: String, turn: ChiefRunningTurn,
                                      in conversation: ConversationID) -> (tool: String, message: MessageID, work: WorkRef)? {
        guard ChiefCloudProvisioning.phase(ofCommand: prompt) == .create, let row = turn.provisioning,
              let message = conversations[conversation]?.message(row), message.parts.count == 1,
              case .work(let work) = message.parts[0], ChiefCloudProvisioning.isProvisioning(work),
              work.status == .running, work.host == nil else { return nil }
        let calls = turn.tools.filter { $0.value == row }.map(\.key)
        guard calls.count == 1, let tool = calls.first, turn.provisioningCalls[tool] == .create else { return nil }
        return (tool, row, work)
    }

    /// After a card's answer: the turn's provisioning row is the one an Allow posted again, none
    /// after a Deny (a retried `vm new` then posts a fresh row).
    ///
    /// - Parameters:
    ///   - work: The work part the card replaced (``ChiefRunningTurn/approvedWork``).
    ///   - tool: Its call id.
    ///   - turn: The running turn; `tools[tool]` is the posted row after an Allow.
    static func resumeProvisioning(after work: WorkRef, tool: String, turn: inout ChiefRunningTurn) {
        guard ChiefCloudProvisioning.isProvisioning(work) else { return }
        turn.provisioning = turn.tools[tool]
        if turn.provisioning == nil { turn.provisioningCalls[tool] = nil }
    }
}
