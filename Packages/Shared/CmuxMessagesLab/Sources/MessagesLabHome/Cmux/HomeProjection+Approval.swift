import CmuxAgentQuestion
import CmuxHomeCore
import CmuxHomeRender
import Foundation

/// Why the approval card's answer did not land (shown under its buttons).
enum HomeApprovalFailure: Error, Equatable {
    /// The host passed no ``HomeApprovalDeciding`` (only Deny can still answer the part).
    case unavailable
    /// The decider refused: acpmux's reason.
    case refused(String)
    /// The conversation owner refused the part's answer.
    case notRecorded(String)
    /// acpmux took the answer (`allowed`: Allow) but the owner refused the part's answer: the
    /// request is settled, so the card keeps its buttons off and says so.
    case decidedNotRecorded(allowed: Bool)

    var reason: String {
        switch self {
        case .unavailable: CmuxStrings.approvalUnavailable
        case .refused(let why), .notRecorded(let why): why
        case .decidedNotRecorded(let allowed): allowed ? CmuxStrings.approvalAllowedNotRecorded : CmuxStrings.approvalDeniedNotRecorded
        }
    }

    /// This Mac's card state after the failure: a settled request keeps its buttons off with a
    /// note; any other failure shows its error and takes clicks again.
    var local: HomeApprovalRowProvider.Local {
        if case .decidedNotRecorded = self { return HomeApprovalRowProvider.Local(busy: true, note: reason) }
        return HomeApprovalRowProvider.Local(error: reason)
    }
}

/// The Chief's approval card (HomeApprovalRowProvider): a click on Allow or Deny answers acpmux as
/// the person (``approvals``), then the question part (`question.answer`), so the card and the
/// Chief both see the answer.
extension HomeProjection {
    /// A click on the card's Allow (`allow`) or Deny of `ref`; false when this projection does not
    /// show that message (another pane's card).
    func decideApproval(_ ref: PartRef, allow: Bool) -> Bool {
        guard let item = shown.first(where: { HomeMapping.id($0, aliases: aliases) == ref.messageId }),
              let message = item.messageID else { return false }
        let partIndex = HomeMapping.homeIndex(ref.partIndex, HomeMapping.projectedParts(item, summary: shownSummary).owners)
        // Only a Chief's own card answers (HomeMapping.approvalCard): another author's look-alike is text.
        guard HomeMapping.isChief(item.author, shownSummary), case .question(let question)? = item.parts[checked: partIndex],
              question.isPending, let permission = question.source.permission,
              let cards = HomeApprovalRowProvider.installed else { return true }
        let key = HomeApprovalRowProvider.key(session: question.source.session, permission: permission)
        guard !cards.local(key).busy else { return true }
        showApproval(key, HomeApprovalRowProvider.Local(busy: true), item: item, ref: ref)
        // task-owner: one decision; ends with the decider's and the owner's answers
        let chief = item.author.rawValue
        Task { [weak self] in
            guard let self else { return }
            let result = await decideApproval(chief: chief, message: message, partIndex: partIndex,
                                              session: question.source.session, permission: permission, allow: allow)
            // The in-flight state is process wide: it ends even when this pane closed meanwhile,
            // so the card is not left disabled in another pane or a reopened one.
            switch result {
            case .success:
                // The answered part replaces the card when the owner's change comes.
                HomeApprovalRowProvider.installed?.setLocal(key, .init())
            case .failure(let failure):
                HomeApprovalRowProvider.installed?.setLocal(key, failure.local)
                if !stopped { showApproval(key, failure.local, item: item, ref: ref) }
            }
        }
        return true
    }

    /// Answers the approval at `partIndex` of `message`: acpmux first (an allow counts only from the
    /// person), then the part. A refused Deny still answers the part: the Chief denies on it.
    func decideApproval(chief: String, message: MessageID, partIndex: Int, session: String, permission: String,
                        allow: Bool) async -> Result<Void, HomeApprovalFailure> {
        var refused: HomeApprovalFailure?
        if let approvals {
            do {
                try await approvals.decide(chief: chief, session: session, permission: permission, allow: allow)
            } catch {
                refused = .refused((error as? LocalizedError)?.errorDescription ?? String(describing: error))
            }
        } else {
            refused = .unavailable
        }
        if allow, let refused { return .failure(refused) }
        let selection = AgentQuestionAnswer.Selection(optionIDs: [allow ? HomeApprovalRowProvider.allowOption : HomeApprovalRowProvider.denyOption])
        let answer = AgentQuestionAnswer(selections: [HomeApprovalRowProvider.item: selection])
        let intent = HomeIntent(op: .answerQuestion(message: message, conversation: conversation, partIndex: partIndex, answer: answer))
        do {
            _ = try await homeStore.perform(intent.op, key: intent.key)
            return .success(())
        } catch {
            // acpmux already took the answer: the request is settled even though the card is not.
            guard let refused else { return .failure(.decidedNotRecorded(allowed: allow)) }
            return .failure(refused)
        }
    }

    /// This Mac's state of an approval (in flight, refused), on the card now.
    private func showApproval(_ key: String, _ local: HomeApprovalRowProvider.Local, item: TranscriptItem, ref: PartRef) {
        guard let cards = HomeApprovalRowProvider.installed else { return }
        cards.setLocal(key, local)
        guard controller.store != nil, case .question(let question)? = item.parts[checked: HomeMapping.homeIndex(ref.partIndex,
                                                                                    HomeMapping.projectedParts(item, summary: shownSummary).owners)],
              case .custom(let card)? = cards.part(question) else { return }
        controller.dispatch(.setCustomPart(ref.messageId, ref.partIndex, card))
    }
}
