import AppKit
import CmuxHomeCore

/// cmux-classic: approval cards (ChiefRows, ChiefApprovalRowProvider) through HomeStore.
///
/// An answer is `HomeOp.answerQuestion` addressing the approval part (CmuxHomeCore has no
/// approval op; the Chief owner reads the choice when the part is an approval). While an
/// approval waits, the field says so ("Allow or deny above to continue") and the header's
/// avatar carries the attention dot ("Waiting for you").
extension HomeProjection {
    func answerApproval(_ ref: PartRef, choice: String, always: Bool, completion: @escaping (Bool) -> Void) {
        guard let item = shown.first(where: { HomeMapping.id($0, aliases: aliases) == ref.messageId }), let message = item.messageID else {
            completion(false)
            return
        }
        let partIndex = HomeMapping.homeIndex(ref.partIndex, HomeMapping.projectedParts(item, summary: shownSummary).owners)
        let op = HomeOp.answerQuestion(message: message, conversation: conversation, partIndex: partIndex,
                                       answer: ChiefApprovalAnswer.answer(choice: choice, always: always))
        let intent = HomeIntent(op: op)
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

    /// The newest approval card still waiting, among the shown messages.
    func newestPendingApproval() -> (ref: PartRef, approval: ChiefRows.Approval)? {
        for item in shown.reversed() where !item.isRetracted {
            let projected = HomeMapping.projectedParts(item, summary: shownSummary).parts
            for (i, part) in projected.enumerated() {
                guard case let .custom(c) = part, c.kind == ChiefRows.approvalKind,
                      let a = c.decode(ChiefRows.Approval.self), a.isPending else { continue }
                return (PartRef(messageId: HomeMapping.id(item, aliases: aliases), partIndex: i), a)
            }
        }
        return nil
    }

    /// The field's placeholder and the header's status follow the newest waiting approval.
    func applyApprovalWait() {
        let waiting = newestPendingApproval() != nil
        controller.demo?.compose.cmuxPlaceholder = waiting ? CmuxStrings.approvalPlaceholder : nil
        controller.host.paneHeader.status = waiting ? CmuxStrings.waitingForYou : nil
        if waiting != isWaitingForApproval {
            isWaitingForApproval = waiting
            onWaitingForApprovalChange(waiting)
        }
    }
}

extension ChatController {
    /// Return or Esc in the field while it is empty and an approval card waits: the card's
    /// tinted option (Return) or its refusing option (Esc). True when a key was taken.
    func answerPendingApproval(prominent: Bool) -> Bool {
        guard let store, store.state.ui.draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              store.state.ui.draft.attachments.isEmpty, let intents, let pending = intents.newestPendingApproval(),
              let option = prominent ? pending.approval.prominent : pending.approval.refusal else { return false }
        let ref = pending.ref
        // The card's own view answers when it is on screen (its buttons dim at once); else the intent.
        if let card = host.approvalCard(for: ref) {
            card.answer(option)
        } else {
            intents.answerApproval(ref, choice: option, always: false) { _ in }
        }
        return true
    }
}

extension HostView {
    /// The live approval card of `ref`, when its row is on screen.
    func approvalCard(for ref: PartRef) -> ChiefApprovalCardView? {
        guard let rows = customRows else { return nil }
        for (_, container) in rows.liveRows where container.ref == ref {
            if let card = container.view as? ChiefApprovalCardView { return card }
        }
        return nil
    }
}
