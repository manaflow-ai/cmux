import CmuxNextDaemon
import CmuxNextHome
import Foundation

/// Owner records (`local-conversations-v1`) to the renderer's value types.
@MainActor
enum HomeMapping {
    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoWhole = ISO8601DateFormatter()

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        return iso.date(from: text) ?? isoWhole.date(from: text)
    }

    static func participant(_ participant: ConversationParticipant) -> HomeParticipant {
        HomeParticipant(id: participant.id, displayName: participant.displayName,
                        isMe: participant.id == ConversationParticipant.localUserID, isAgent: participant.kind == .agent)
    }

    static func part(_ part: ConversationPart) -> HomePart {
        switch part {
        case .text(let text, let runs):
            return .text(text, mentions: runs.compactMap { run in
                run.mention.map { HomeMention(start: run.start, length: run.length, participantID: $0) }
            })
        case .work(let session, _, let status, let preview):
            return .work(session: session, status: HomeWorkStatus(rawValue: status) ?? .running, preview: preview)
        case .unknown(let type, _):
            return .fallback(type)
        }
    }

    static func message(_ message: ConversationMessage) -> HomeMessage {
        HomeMessage(id: message.id, seq: Int(message.seq), clientMsgID: message.clientMsgID, authorID: message.author,
                    parts: message.parts.map(part), replyTo: message.replyTo?.messageID,
                    createdAt: date(message.createdAt) ?? .distantPast,
                    delivery: message.author == ConversationParticipant.localUserID ? .sent : .none,
                    reactions: message.reactions.map(reaction), editedAt: date(message.editedAt), retractedAt: date(message.retractedAt))
    }

    static func pending(_ send: PendingConversationSend) -> HomeMessage {
        let delivery: HomeDelivery
        if case .failed(let reason) = send.state { delivery = .failed(reason) } else { delivery = .sending }
        return HomeMessage(id: "pending:\(send.clientMsgID)", seq: nil, clientMsgID: send.clientMsgID,
                           authorID: ConversationParticipant.localUserID, parts: send.parts.map(part),
                           replyTo: send.replyTo?.messageID, createdAt: send.createdAt, delivery: delivery)
    }

    static func reaction(_ reaction: ConversationReaction) -> HomeReaction {
        let kind: String
        switch reaction.kind {
        case .tapback(let value): kind = value
        case .emoji(let value): kind = value
        }
        return HomeReaction(authorID: reaction.author, partIndex: reaction.partIndex, kind: kind)
    }

    static func summary(_ summary: ConversationSummary, owner: String) -> HomeConversationSummary {
        HomeConversationSummary(id: summary.id, title: summary.title, participants: summary.participants.map(participant),
                                lastMessagePreview: summary.lastMessage?.parts.first?.plainText ?? "",
                                updatedAt: date(summary.updatedAt) ?? .distantPast,
                                unreadCount: Int(summary.unreadCount(for: ConversationParticipant.localUserID)), ownerLabel: owner)
    }
}
