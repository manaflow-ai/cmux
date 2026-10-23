#if os(iOS)
import CmuxAgentQuestion
import CmuxMobileFeed
import CmuxMobileNotifications
import CmuxMobileTransport
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "push")

/// A notification's answer to a terminal agent's question: the same Feed card
/// and the same keys as an answer from the Feed (`TerminalFeed.answer`), on
/// the reply's Mac. Answers are foreground actions (verify/rich-push.md): the
/// app is open when this runs, never a lock-screen write into a terminal.
extension LiveCoordinator {
    func deliverToTerminal(_ reply: PushReply, tabID: String, budget: Duration) async throws {
        let mac = reply.mac
        guard await waitUntil(within: budget, { [weak self] in self?.sessions[mac]?.workspaces.daemon != nil }),
              let session = sessions[mac] else {
            log.error("push reply: no link to that Mac within the budget")
            throw PushReplyFailure(reason: .unreachable)
        }
        // A push that names no question (an older Mac) is answered from the Feed card.
        guard reply.eventId?.hasPrefix("q-") == true else {
            throw PushReplyFailure(reason: .refused(String(localized: "Answer this question from its card in the Feed.")))
        }
        // The card shows once the ledger is read on this link.
        if session.terminalFeed.pendingQuestion(tabID: tabID, eventID: reply.eventId) == nil { await session.terminalFeed.refresh() }
        guard let (item, question) = session.terminalFeed.pendingQuestion(tabID: tabID, eventID: reply.eventId) else {
            throw PushReplyFailure(reason: .refused(String(localized: "This was already answered.")))
        }
        let plan: PushReplyPlan
        do {
            plan = try PushReplyPlan.make(reply, pending: .question(question))
        } catch let refusal as PushReplyPlan.Refusal {
            throw PushReplyFailure(reason: .refused(refusal.message))
        }
        switch plan {
        case .answer(_, let answer):
            try await terminalAnswer(session.terminalFeed, item: item, question: question) {
                try await session.terminalFeed.answer(item, question: question, with: answer)
            }
            // The Feed card says what was answered, as an answer from the card does.
            feedStore.resolveElsewhere(item.id, text: question.summaryLines(answer).joined(separator: "\n"))
        case .decline:
            try await terminalAnswer(session.terminalFeed, item: item, question: question) {
                try await session.terminalFeed.decline(item, question: question)
            }
            feedStore.resolveElsewhere(item.id, text: String(localized: "Declined"))
        default:
            throw PushReplyFailure(reason: .refused(String(localized: "Answer this one in the terminal.")))
        }
        log.info("push reply typed into the terminal")
    }

    private func terminalAnswer(_ feed: TerminalFeed, item: FeedItem, question: AgentQuestion,
                                _ send: () async throws -> Void) async throws {
        do {
            try await send()
        } catch let refused as TerminalFeed.QuestionRefused {
            throw PushReplyFailure(reason: .refused(refused.message))
        } catch let error as LinkError {
            log.error("push reply failed on the link: \(error.message, privacy: .public)")
            throw PushReplyFailure(reason: .unreachable)
        }
    }
}
#endif
