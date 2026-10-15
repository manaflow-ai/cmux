import AppKit
import CmuxAgentQuestion
import CmuxHomeCore

/// cmux-classic: the Chief's question cards (QuestionCardRow) and Cloud result cards
/// (ChiefCloudRows) through HomeStore and the host.
extension HomeProjection {
    /// A question card's answer: `HomeOp.answerQuestion` addressing the question part. The
    /// owner stores it (the card turns into its receipt) and hands it to the Chief as a turn.
    func answerQuestion(_ ref: PartRef, answer: AgentQuestionAnswer, completion: @escaping (Bool) -> Void) {
        guard let item = shown.first(where: { HomeMapping.id($0, aliases: aliases) == ref.messageId }), let message = item.messageID else {
            completion(false)
            return
        }
        let partIndex = HomeMapping.homeIndex(ref.partIndex, HomeMapping.projectedParts(item, summary: shownSummary).owners)
        let intent = HomeIntent(op: .answerQuestion(message: message, conversation: conversation, partIndex: partIndex, answer: answer))
        let homeStore = self.homeStore
        // task-owner: one op; ends with the owner's answer
        Task { [weak self] in
            do {
                _ = try await homeStore.perform(intent.op, key: intent.key)
                completion(true)
            } catch let rejection as HomeRejection {
                completion(false)
                self?.onRefusal(intent, rejection)
            } catch {
                completion(false)
            }
        }
    }

    func openCloudWorkspace(machine: String, workspace: String) {
        onOpenCloudWorkspace(machine, workspace)
    }

    func retryLastTurn(completion: @escaping (Bool) -> Void) {
        onRetryLastTurn(completion)
    }

    func undoMemory(fact: String, completion: @escaping (Bool) -> Void) {
        onUndoMemory(fact, completion)
    }
}
