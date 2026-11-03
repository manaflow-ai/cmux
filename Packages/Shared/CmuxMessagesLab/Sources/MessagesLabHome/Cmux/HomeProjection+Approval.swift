import AppKit
import CmuxAgentQuestion
import CmuxHomeCore
import CmuxHomeRender

/// A native pointer gesture, valid for one decision and at most five seconds.
/// A debug/socket call to `clicked` without a real AppKit event grants nothing.
@MainActor final class HomeApprovalGesture {
    private static var latest: TimeInterval = -1
    static func capture(in window: NSWindow?) -> HomeApprovalWriteGate? {
        guard let window, let event = NSApp.currentEvent, event.window === window,
              event.type == .leftMouseUp || event.type == .leftMouseDown,
              event.timestamp > latest,
              (0..<5).contains(ProcessInfo.processInfo.systemUptime - event.timestamp) else { return nil }
        latest = event.timestamp
        return HomeApprovalWriteGate(deadline: event.timestamp + 5)
    }
}

extension HomeProjection {
    /// Only a committed card from a Chief participant in a local conversation is actionable.
    func decideApproval(_ ref: PartRef, allow: Bool) -> Bool {
        guard !stopped, let item = shown.first(where: { HomeMapping.id($0, aliases: aliases) == ref.messageId }) else { return false }
        let index = HomeMapping.homeIndex(ref.partIndex, HomeMapping.projectedParts(item, summary: shownSummary).owners)
        guard shownSummary?.owner == .local, HomeMapping.isChief(item.author, shownSummary), let message = item.messageID,
              case .question(let question)? = item.parts[checked: index], question.isPending,
              HomeApprovalRowProvider.digest(question) != nil, let permission = question.source.permission,
              let requestJSON = question.items.first?.options.first(where: { $0.id == "allow" })?.preview?.text else { return true }
        let cards = HomeApprovalRowProvider.shared
        guard !cards.local(question.id).busy, !cards.local(question.id).ended else { return true }
        guard let gesture = HomeApprovalGesture.capture(in: controller.window) else {
            showApproval(question, ref: ref, local: .init(note: CmuxStrings.approvalFailed))
            return true
        }
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
        HomeApprovalRowProvider.shared.setLocal(question.id, local)
        guard !stopped, controller.store != nil, case .custom(let card)? = HomeApprovalRowProvider.shared.part(question) else { return }
        controller.dispatch(.setCustomPart(ref.messageId, ref.partIndex, card))
    }
}
