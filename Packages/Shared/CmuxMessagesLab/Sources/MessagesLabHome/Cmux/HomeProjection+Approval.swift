import AppKit
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
            let connect = HomeApprovalRowProvider.isConnect(question)
            return .init(note: allow ? (connect ? CmuxStrings.approvalConnected : CmuxStrings.approvalAllowed)
                                     : (connect ? CmuxStrings.approvalNotConnected : CmuxStrings.approvalDenied), ended: true)
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
    }
}
