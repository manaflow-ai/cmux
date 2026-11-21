import AppKit
import CmuxAgentQuestion
import CmuxHomeCore
import CmuxHomeRender

/// One question card's picks and state, kept by the view (HomeQuestionRowProvider.Local).
struct HomeQuestionDisplay {
    let question: AgentQuestion
    let ref: PartRef
    let local: HomeQuestionRowProvider.Local
}

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

    /// The pending question `ref` shows, when it is a Chief participant's in a local conversation and
    /// not a tool approval (``decideApproval(_:allow:)`` answers those natively).
    private func localQuestion(_ ref: PartRef) -> (chief: String, message: MessageID, index: Int, question: AgentQuestion)? {
        guard !stopped, let item = shown.first(where: { HomeMapping.id($0, aliases: aliases) == ref.messageId }) else { return nil }
        let index = HomeMapping.homeIndex(ref.partIndex, HomeMapping.projectedParts(item, summary: shownSummary).owners)
        guard shownSummary?.owner == .local, HomeMapping.isChief(item.author, shownSummary), let message = item.messageID,
              case .question(let question)? = item.parts[checked: index], question.isPending,
              HomeApprovalRowProvider.digest(question) == nil else { return nil }
        return (item.author.rawValue, message, index, question)
    }

    /// Answers a pending question from a Chief participant in a local conversation, after a
    /// native click. Every Home question answer carries the person's decision, signed with the app's
    /// key after that click. The owner delivers it to acpmux and records it only when acpmux takes it.
    @discardableResult
    func answerQuestion(_ ref: PartRef, answer: AgentQuestionAnswer,
                        done: @escaping @MainActor (HomeQuestionOutcome) -> Void = { _ in }) -> Bool {
        guard let local = localQuestion(ref), answer.problems(for: local.question).isEmpty else { return false }
        guard let gesture = HomeApprovalGesture.capture(in: controller.window, after: approvalLatestEvent,
                                                       isPerson: isPersonApprovalEvent) else {
            done(.refused)
            return true
        }
        approvalLatestEvent = NSApp.currentEvent?.timestamp ?? approvalLatestEvent
        approvalWrites.append(gesture)
        // task-owner: one native question answer: signed here, then delivered by the conversation owner.
        Task {
            let outcome = await completeQuestion(chief: local.chief, answer: answer, message: local.message,
                                                 partIndex: local.index, displayed: local.question.displayedJSON, through: { body in gesture.write(body) })
            gesture.cancel()
            approvalWrites.removeAll { $0 === gesture }
            done(outcome)
        }
        return true
    }

    /// A click on a question card: an option changes only the card's picks; Send answers with them.
    func questionAction(_ ref: PartRef, _ target: HomeQuestionRowProvider.Target) {
        guard let question = localQuestion(ref)?.question else { return }
        let local = questionCards[question.id]?.local ?? .init()
        guard !local.busy, !local.ended else { return }
        switch target {
        case .option(let itemID, let option):
            guard let item = question.items.first(where: { $0.id == itemID }) else { return }
            showQuestion(question, ref: ref, local: HomeQuestionRowProvider.toggled(local, item: item, option: option))
        case .send:
            let answer = HomeQuestionRowProvider.answer(.init(question: question, local: local))
            var busy = local
            busy.busy = true
            busy.note = nil
            showQuestion(question, ref: ref, local: busy)
            let started = answerQuestion(ref, answer: answer) { [weak self] outcome in
                var after = local
                switch outcome {
                case .answered: after.ended = true
                // Not ended here: a question the owner still shows as pending (a re-issued prompt) stays
                // answerable, and refreshQuestionStates drops the card once the owner closes it.
                case .expired: after.note = CmuxStrings.questionExpired
                case .refused: after.note = CmuxStrings.approvalFailed
                }
                self?.showQuestion(question, ref: ref, local: after)
            }
            if !started {
                var refused = local
                refused.note = CmuxStrings.approvalFailed
                showQuestion(question, ref: ref, local: refused)
            }
        }
    }

    private func showQuestion(_ question: AgentQuestion, ref: PartRef, local: HomeQuestionRowProvider.Local) {
        questionCards[question.id] = HomeQuestionDisplay(question: question, ref: ref, local: local)
        refreshQuestionStates()
    }

    /// The cards' picks and in-flight state belong to this view: reapply them after an owner refresh
    /// (the renderer caches the payload). A card whose question closed drops its state.
    func refreshQuestionStates() {
        guard !stopped, !questionCards.isEmpty, let store = controller.store else { return }
        for display in Array(questionCards.values) {
            guard let message = store.state.conversation.messages.first(where: { $0.id == display.ref.messageId }),
                  case .custom(let current)? = message.parts[checked: display.ref.partIndex],
                  let payload = HomeQuestionRowProvider.payload(current),
                  payload.question.id == display.question.id, payload.question.isPending else {
                questionCards[display.question.id] = nil
                continue
            }
            guard case .custom(let card)? = HomeQuestionRowProvider.part(display.question, local: display.local),
                  card.version != current.version else { continue }
            controller.dispatch(.setCustomPart(display.ref.messageId, display.ref.partIndex, card))
        }
    }

    /// Signs the answer's decision, then has the owner deliver and record the answer with it. No
    /// answer goes to the owner without a decision.
    func completeQuestion(chief: String, answer: AgentQuestionAnswer, message: MessageID, partIndex: Int,
                          displayed: String? = nil, through gate: @escaping @Sendable (() -> Void) -> Bool) async -> HomeQuestionOutcome {
        guard let questions, let answerJSON = try? AgentQuestionAnswer(selections: answer.selections).conversationAnswer.data()
        else { return .refused }
        let request = HomeQuestionRequest(chief: chief, conversation: conversation.rawValue, message: message.rawValue,
                                          partIndex: partIndex, answerJSON: answerJSON,
                                          displayedQuestionJSON: displayed)
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
