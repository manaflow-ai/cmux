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

    var reason: String {
        switch self {
        case .unavailable: CmuxStrings.approvalUnavailable
        case .refused(let why), .notRecorded(let why): why
        }
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
        guard case .question(let question)? = item.parts[checked: partIndex], question.isPending,
              let permission = question.source.permission, let cards = HomeApprovalRowProvider.installed else { return true }
        let key = HomeApprovalRowProvider.key(session: question.source.session, permission: permission)
        guard !cards.local(key).busy else { return true }
        showApproval(key, HomeApprovalRowProvider.Local(busy: true), item: item, ref: ref)
        // task-owner: one decision; ends with the decider's and the owner's answers
        Task { [weak self] in
            guard let self else { return }
            let result = await decideApproval(message: message, partIndex: partIndex, session: question.source.session,
                                              permission: permission, allow: allow)
            guard !stopped else { return }
            switch result {
            case .success:
                // The answered part replaces the card when the owner's change comes.
                HomeApprovalRowProvider.installed?.setLocal(key, .init())
            case .failure(let failure):
                showApproval(key, HomeApprovalRowProvider.Local(error: failure.reason), item: item, ref: ref)
            }
        }
        return true
    }

    /// Answers the approval at `partIndex` of `message`: acpmux first (an allow counts only from the
    /// person), then the part. A refused Deny still answers the part: the Chief denies on it.
    func decideApproval(message: MessageID, partIndex: Int, session: String, permission: String,
                        allow: Bool) async -> Result<Void, HomeApprovalFailure> {
        var refused: HomeApprovalFailure?
        if let approvals {
            do {
                try await approvals.decide(session: session, permission: permission, allow: allow)
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
        } catch let rejection as HomeRejection {
            return .failure(refused ?? .notRecorded(String(describing: rejection)))
        } catch {
            return .failure(refused ?? .notRecorded(String(describing: error)))
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
