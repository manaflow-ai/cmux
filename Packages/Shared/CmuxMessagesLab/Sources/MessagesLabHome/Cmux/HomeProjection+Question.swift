import AppKit
import CmuxAgentQuestion
import CmuxHomeCore
import CmuxHomeRender

/// What answering one Chief question from Home came to.
enum HomeQuestionOutcome: Equatable {
    /// The owner delivered the answer with the person's decision, and recorded it.
    case answered
    /// The question ended or changed since it was read.
    case expired
    /// Not answered: no native click, not the person's, or the owner refused.
    case refused
}

extension HomeProjection {
    /// The native signer of question answers: the same decider that answers approvals.
    var questions: (any HomeQuestionDeciding)? { approvals as? any HomeQuestionDeciding }

    /// Answers a pending question from a Chief participant in a local conversation, after a
    /// native click. Every Home question answer carries the person's decision, signed with the app's
    /// key after that click. The owner delivers it to acpmux and records it only when acpmux takes it.
    /// An approval card (``decideApproval(_:allow:)``) is answered natively instead.
    @discardableResult
    func answerQuestion(_ ref: PartRef, answer: AgentQuestionAnswer,
                        done: @escaping @MainActor (HomeQuestionOutcome) -> Void = { _ in }) -> Bool {
        guard !stopped, let item = shown.first(where: { HomeMapping.id($0, aliases: aliases) == ref.messageId }) else { return false }
        let index = HomeMapping.homeIndex(ref.partIndex, HomeMapping.projectedParts(item, summary: shownSummary).owners)
        guard shownSummary?.owner == .local, HomeMapping.isChief(item.author, shownSummary), let message = item.messageID,
              case .question(let question)? = item.parts[checked: index], question.isPending,
              HomeApprovalRowProvider.digest(question) == nil, answer.problems(for: question).isEmpty else { return false }
        guard let gesture = HomeApprovalGesture.capture(in: controller.window, after: approvalLatestEvent,
                                                       isPerson: isPersonApprovalEvent) else {
            done(.refused)
            return true
        }
        approvalLatestEvent = NSApp.currentEvent?.timestamp ?? approvalLatestEvent
        approvalWrites.append(gesture)
        // task-owner: one native question answer: signed here, then delivered by the conversation owner.
        Task {
            let outcome = await completeQuestion(chief: item.author.rawValue, answer: answer, message: message,
                                                 partIndex: index, through: { body in gesture.write(body) })
            gesture.cancel()
            approvalWrites.removeAll { $0 === gesture }
            done(outcome)
        }
        return true
    }

    /// Signs the answer's decision, then has the owner deliver and record the answer with it. No
    /// answer goes to the owner without a decision.
    func completeQuestion(chief: String, answer: AgentQuestionAnswer, message: MessageID, partIndex: Int,
                          through gate: @escaping @Sendable (() -> Void) -> Bool) async -> HomeQuestionOutcome {
        guard let questions, let answerJSON = try? AgentQuestionAnswer(selections: answer.selections).conversationAnswer.data()
        else { return .refused }
        let request = HomeQuestionRequest(chief: chief, conversation: conversation.rawValue, message: message.rawValue,
                                          partIndex: partIndex, answerJSON: answerJSON)
        let signed: String
        switch await questions.decide(request, through: gate) {
        case .expired: return .expired
        case .refused: return .refused
        case .signed(let decision): signed = decision
        }
        guard let decision = try? AgentQuestionJSON(data: Data(signed.utf8)) else { return .refused }
        var answer = answer
        answer.decision = decision
        do {
            _ = try await homeStore.perform(.answerQuestion(message: message, conversation: conversation, partIndex: partIndex, answer: answer))
            return .answered
        } catch {
            return .refused
        }
    }
}
