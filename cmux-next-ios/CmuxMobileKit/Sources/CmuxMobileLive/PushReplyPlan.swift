import CmuxAgentQuestion
import CmuxMobileAgentChat
import CmuxMobileNotifications
import Foundation

/// What a notification reply asks the Mac for, once the phone read the
/// prompt it answers (`_acpmux/info`): the same calls the chat and the Feed
/// make (verify/rich-push.md, "Reply delivery").
public enum PushReplyPlan: Equatable, Sendable {
    /// `AcpmuxHub.answer`: signed after Face ID.
    case answer(AgentQuestion, AgentQuestionAnswer)
    /// `AcpmuxHub.decline`: the question's reject, unsigned.
    case decline(AgentQuestion)
    /// `AcpmuxHub.respond`: signed for an allow, unsigned for a reject.
    case respond(sessionID: String, permissionID: String, optionID: String)
    /// `session/prompt` to the session, with `promptId` the reply's id (acpmux runs each once).
    case prompt(sessionID: String, text: String, attachments: [String], promptID: String)
    /// A message to that Mac's Chief.
    case chief(text: String, attachments: [String])
    /// Text into the terminal that posted a notification: daemon
    /// `notification-reply {notification, text}` (PR B; device unlock).
    case terminal(notification: String, text: String)

    /// The `notification-reply` params for a terminal reply. `reply_id` is the
    /// reply's id, the same one its mailbox copy carries, so the Mac applies a
    /// reply once whichever way it arrives first.
    public static func terminalRequest(notification: String, text: String, replyID: UUID) -> [String: Any] {
        let id: Any = Int(notification).map { $0 as Any } ?? notification
        return ["notification": id, "text": text, "reply_id": replyID.uuidString.lowercased()]
    }

    /// What the daemon said to a `notification-reply`.
    public enum TerminalAnswer: Equatable, Sendable {
        /// Applied now, or already applied (`duplicate`: the same reply id came first another way).
        case delivered
        case refused(String)
    }

    public static func terminalAnswer(_ data: Data) -> TerminalAnswer {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .delivered }
        if object["error"] != nil || object["ok"] as? Bool == false {
            let message = ((object["error"] as? [String: Any])?["message"] as? String) ?? (object["error"] as? String)
            return .refused(message ?? String(localized: "The terminal didn't take the reply."))
        }
        return .delivered
    }

    public struct Refusal: Error, Equatable, Sendable {
        public var message: String

        public init(_ message: String) {
            self.message = message
        }
    }

    /// The plan for `reply`, given what the prompt it answers is now (nil: no
    /// such prompt is pending, for an ask). Throws a refusal a person can read.
    public static func make(_ reply: PushReply, pending: AgentSessionEvent?) throws -> PushReplyPlan {
        switch reply.action {
        case .text(let text, let attachments):
            if reply.kind == .chief { return .chief(text: text, attachments: attachments) }
            if reply.kind == .terminal {
                guard let notification = reply.notificationId else { throw Refusal(String(localized: "This notification takes no reply.")) }
                guard attachments.isEmpty else { throw Refusal(String(localized: "A terminal takes text only.")) }
                guard text.utf8.count <= MailboxReply.maxTextBytes else { throw Refusal(String(localized: "That reply is too long for a terminal.")) }
                return .terminal(notification: notification, text: text)
            }
            guard let session = reply.sessionId else { throw Refusal(String(localized: "This notification names no chat.")) }
            return .prompt(sessionID: session, text: text, attachments: attachments, promptID: reply.id.uuidString.lowercased())
        case .option, .answers, .allow, .deny:
            break
        }
        guard let pending else { throw Refusal(String(localized: "This was already answered.")) }
        switch (pending, reply.action) {
        case (.question(let question), .option(let index, let label)):
            // The option there must still read as the button did (review M1): never guess another.
            guard let item = question.items.first, item.options.indices.contains(index),
                  PushLabel.matches(sent: label, live: item.options[index].label) else {
                throw Refusal(String(localized: "That choice is no longer offered. Open the question to answer it."))
            }
            return .answer(question, AgentQuestionAnswer(selections: [item.id: .init(optionIDs: [item.options[index].id])]))
        case (.question(let question), .answers(let selected, let other)):
            var selections: [String: AgentQuestionAnswer.Selection] = [:]
            for (i, item) in question.items.enumerated() {
                let labels = i < selected.count ? selected[i] : []
                // Each label names exactly one live option (a cut label matches by its start).
                var ids: [String] = []
                for label in labels {
                    let found = item.options.filter { PushLabel.matches(sent: label, live: $0.label) }
                    guard found.count == 1, let option = found.first else {
                        throw Refusal(String(localized: "That choice is no longer offered. Open the question to answer it."))
                    }
                    if !ids.contains(option.id) { ids.append(option.id) }
                }
                ids = item.options.map(\.id).filter(ids.contains)
                selections[item.id] = .init(optionIDs: ids, other: i < other.count && item.allowsOther ? other[i] : nil)
            }
            let answer = AgentQuestionAnswer(selections: selections)
            if !answer.problems(for: question).isEmpty { throw Refusal(String(localized: "Answer every question first.")) }
            return .answer(question, answer)
        case (.question(let question), .deny):
            return .decline(question)
        case (.permissionRequest(let request), .allow(let optionID)):
            guard request.options.contains(where: { $0.id == optionID && $0.isAllow }) else {
                throw Refusal(String(localized: "That choice is no longer offered."))
            }
            return .respond(sessionID: reply.sessionId ?? "", permissionID: request.id, optionID: optionID)
        case (.permissionRequest(let request), .deny(let optionID)):
            let rejects = request.options.filter { !$0.isAllow }
            guard let option = rejects.first(where: { $0.id == optionID }) ?? rejects.first(where: { $0.kind == .rejectOnce }) ?? rejects.first else {
                throw Refusal(String(localized: "This request can't be denied from a notification."))
            }
            return .respond(sessionID: reply.sessionId ?? "", permissionID: request.id, optionID: option.id)
        default:
            throw Refusal(String(localized: "This was already answered."))
        }
    }
}
