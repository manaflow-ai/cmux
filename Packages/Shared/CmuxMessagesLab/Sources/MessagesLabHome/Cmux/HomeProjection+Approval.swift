import AppKit
<<<<<<< HEAD
import CmuxAgentQuestion
import CmuxHomeCore
import CmuxHomeRender

/// A native pointer gesture, valid for one decision and at most five seconds.
/// A debug/socket call to `clicked` without a real AppKit event grants nothing.
@MainActor final class HomeApprovalGesture {
    static func capture(in window: NSWindow?, after latest: TimeInterval = -1,
                        isPerson: (NSEvent) -> Bool = { _ in false }) -> HomeApprovalWriteGate? {
        guard let event = NSApp.currentEvent else { return nil }
        return capture(event, in: window, after: latest, isPerson: isPerson)
    }
    static func capture(_ event: NSEvent, in window: NSWindow?, after latest: TimeInterval,
                        isPerson: (NSEvent) -> Bool) -> HomeApprovalWriteGate? {
        guard let window, event.window === window, isPerson(event),
              event.type == .leftMouseUp || event.type == .leftMouseDown,
              event.timestamp > latest,
              (0..<5).contains(ProcessInfo.processInfo.systemUptime - event.timestamp) else { return nil }
        return HomeApprovalWriteGate(deadline: event.timestamp + 5)
    }
}

struct HomeApprovalDisplay {
    let question: AgentQuestion
    let ref: PartRef
    let local: HomeApprovalRowProvider.Local
}

extension HomeProjection {
    func approvalState(_ key: String) -> HomeApprovalRowProvider.Local { approvalCards[key]?.local ?? .init() }

    /// Only a committed card from a Chief participant in a local conversation is actionable.
    func decideApproval(_ ref: PartRef, allow: Bool) -> Bool {
        guard !stopped, let item = shown.first(where: { HomeMapping.id($0, aliases: aliases) == ref.messageId }) else { return false }
        let index = HomeMapping.homeIndex(ref.partIndex, HomeMapping.projectedParts(item, summary: shownSummary).owners)
        guard shownSummary?.owner == .local, HomeMapping.isChief(item.author, shownSummary), let message = item.messageID,
              case .question(let question)? = item.parts[checked: index], question.isPending,
              HomeApprovalRowProvider.digest(question) != nil, let permission = question.source.permission,
              let requestJSON = question.items.first?.options.first(where: { $0.id == "allow" })?.preview?.text else { return true }
        guard !approvalState(question.id).busy, !approvalState(question.id).ended else { return true }
        guard let gesture = HomeApprovalGesture.capture(in: controller.window, after: approvalLatestEvent,
                                                       isPerson: isPersonApprovalEvent) else {
            showApproval(question, ref: ref, local: .init(note: CmuxStrings.approvalFailed))
            return true
        }
        approvalLatestEvent = NSApp.currentEvent?.timestamp ?? approvalLatestEvent
        approvalWrites.append(gesture)
        showApproval(question, ref: ref, local: .init(busy: true))
        let request = HomeApprovalRequest(chief: item.author.rawValue, session: question.source.session,
                                          permission: permission, requestJSON: requestJSON)
        // task-owner: one native card decision, through acpmux and then the conversation owner.
        Task {
            let local = await completeApproval(request, allow: allow, question: question, message: message, partIndex: index,
                                               through: { bytes in gesture.write(bytes) })
            gesture.cancel()
            approvalWrites.removeAll { $0 === gesture }
            showApproval(question, ref: ref, local: local)
        }
        return true
    }

    /// No card answer is recorded until acpmux confirms that its pending request was answered.
    /// An answered request remains disabled even when recording the card fails.
    func completeApproval(_ request: HomeApprovalRequest, allow: Bool, question: AgentQuestion,
                          message: MessageID, partIndex: Int, through gate: @escaping @Sendable (() -> Void) -> Bool) async -> HomeApprovalRowProvider.Local {
        guard let approvals else { return .init(note: CmuxStrings.approvalFailed) }
        switch await approvals.decide(request, allow: allow, through: gate) {
        case .expired: return .init(note: CmuxStrings.approvalExpired, ended: true)
        case .refused: return .init(note: CmuxStrings.approvalFailed)
        case .answered: break
        }
        let selection = AgentQuestionAnswer.Selection(optionIDs: [allow ? "allow" : "deny"])
        guard let item = question.items.first else { return .init(ended: true) }
        let answer = AgentQuestionAnswer(selections: [item.id: selection])
        do {
            _ = try await homeStore.perform(.answerQuestion(message: message, conversation: conversation, partIndex: partIndex, answer: answer))
            return .init(note: allow ? CmuxStrings.approvalAllowed : CmuxStrings.approvalDenied, ended: true)
        } catch {
            return .init(note: allow ? CmuxStrings.approvalAllowedNotRecorded : CmuxStrings.approvalDeniedNotRecorded, ended: true)
        }
    }

    private func showApproval(_ question: AgentQuestion, ref: PartRef, local: HomeApprovalRowProvider.Local) {
        approvalCards[question.id] = HomeApprovalDisplay(question: question, ref: ref, local: local)
        refreshApprovalStates()
    }

    /// Native in-flight/result state belongs to this view. Reapply only these
    /// few rows after an owner refresh; the stateless renderer caches the payload.
    func refreshApprovalStates() {
        guard !stopped, !approvalCards.isEmpty, let store = controller.store else { return }
        for display in Array(approvalCards.values) {
            guard let message = store.state.conversation.messages.first(where: { $0.id == display.ref.messageId }),
                  case .custom(let current)? = message.parts[checked: display.ref.partIndex],
                  let payload = HomeApprovalRowProvider.payload(current),
                  payload.question.id == display.question.id, payload.question.isPending else {
                approvalCards[display.question.id] = nil
                continue
            }
            guard case .custom(let card)? = HomeApprovalRowProvider.part(display.question, local: display.local),
                  card.version != current.version else { continue }
            controller.dispatch(.setCustomPart(display.ref.messageId, display.ref.partIndex, card))
        }
=======
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
        // The decision ends the wait now: the status line, the header's status and the field's placeholder
        // leave with the click, not with the owner's answer (a refusal brings them back).
        answeredApprovals.insert(ref)
        applyApprovalWait()
        // task-owner: one op; ends with the owner's answer
        Task { [weak self] in
            do {
                _ = try await homeStore.perform(intent.op, key: intent.key)
                completion(true)
            } catch let rejection as HomeRejection {
                self?.answerFailed(ref)
                completion(false)
                self?.onRefusal(intent, rejection)
            } catch {
                self?.answerFailed(ref)
                completion(false)
            }
        }
    }

    /// The answer did not reach the owner: the card waits again.
    private func answerFailed(_ ref: PartRef) {
        guard answeredApprovals.remove(ref) != nil else { return }
        applyApprovalWait()
    }

    /// The newest approval card still waiting, among the shown messages (a scan of the raw parts;
    /// only a found card's message is projected, for its part index).
    /// A card answered here (`answeredApprovals`) no longer waits, though HomeStore has not shown its decision yet.
    func newestPendingApproval() -> (ref: PartRef, approval: ChiefRows.Approval)? {
        for item in shown.reversed() where !item.isRetracted {
            for (homeIndex, part) in item.parts.enumerated() {
                guard case .approval(let ref) = part, ref.decided == nil else { continue }
                let owners = HomeMapping.projectedParts(item, summary: shownSummary).owners
                let shownRef = PartRef(messageId: HomeMapping.id(item, aliases: aliases), partIndex: HomeMapping.projectedIndex(homeIndex, owners))
                if answeredApprovals.contains(shownRef) { continue }
                let agent = shownSummary?.participants.first { $0.id == item.author }?.displayName
                return (shownRef, ChiefRows.Approval(ref, agent: agent))
            }
        }
        return nil
    }

    /// The field's placeholder, the header's status, the transcript's status line and the
    /// Stop button follow the newest waiting approval.
    func applyApprovalWait() {
        let waiting = newestPendingApproval() != nil
        controller.demo?.compose.cmuxPlaceholder = waiting ? CmuxStrings.approvalPlaceholder : nil
        controller.host.paneHeader.status = waiting ? CmuxStrings.waitingForYou : nil
        // "Waiting for you" is the transcript's last row (MessagesLab's ask 9 status line, 8 pt under
        // the card, scrolled with it), not a line over the transcript's bottom edge.
        let line = waiting ? CmuxStrings.waitingForYou : nil
        if let store = controller.store, store.state.ui.notice != line { controller.dispatch(.setNotice(line)) }
        controller.isWaitingForApproval = waiting
        if waiting != isWaitingForApproval {
            isWaitingForApproval = waiting
            onWaitingForApprovalChange(waiting)
        }
    }
}

/// cmux-classic: the transcript's status line (`.setNotice`, RowDrawing's `.notice` row): 10 pt in the
/// attention colour, as the sidebar's "Needs you" and the header avatar's dot (system orange).
/// Read on the row render threads: fixed sRGB values, not the dynamic system colour.
enum HomeStatusLine {
    static let font = HomeFonts.system(ofSize: 10, weight: .medium)
    static var ink: NSColor {
        Fixture.lightAppearance ? NSColor(srgbRed: 1, green: 149 / 255, blue: 0, alpha: 1)
                                : NSColor(srgbRed: 1, green: 159 / 255, blue: 10 / 255, alpha: 1)
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
>>>>>>> origin/main
    }
}
