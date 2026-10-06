import CmuxHomeCore
import CmuxNextDaemon
import Foundation

/// The local conversation owner's wire types (CmuxNextDaemon) as the shared
/// Home core's types (CmuxHomeCore, plans/cmux-next/home-mac.md). Pure; the
/// owner's ids and seqs pass through unchanged.
nonisolated enum HomeCoreMapping {
    nonisolated(unsafe) private static let dates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()  // ISO8601DateFormatter is thread safe.

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        return dates.date(from: text)
    }

    /// The local mux is the chief (N1: "Chief").
    static func participant(_ participant: ConversationParticipant) -> Participant {
        let isChief = participant.kind == .agent && participant.agentClass == "mux"
        return Participant(id: ParticipantID(participant.id), kind: participant.kind == .agent ? .agent : .human,
                           displayName: isChief ? HomeStrings.chiefName : participant.displayName,
                           agentClass: participant.kind == .agent ? (isChief ? .chief : .agent) : nil)
    }

    static func part(_ part: ConversationPart) -> MessagePart {
        switch part {
        case .text(let text, let runs):
            let mentions = runs.compactMap { run in
                run.mention.map { Mention(start: run.start, length: run.length, participant: ParticipantID($0)) }
            }
            return .text(text, mentions: mentions)
        case .work(let session, let host, let status, let preview):
            return .work(WorkRef(session: session, host: host, title: session,
                                 status: WorkRef.Status(rawValue: status) ?? .running, preview: preview))
        case .unknown(let type, _):
            return .text(type)
        }
    }

    static func reaction(_ reaction: ConversationReaction) -> Reaction {
        let kind: Reaction.Kind = switch reaction.kind {
        case .tapback(let value): Reaction.Tapback(rawValue: value).map(Reaction.Kind.tapback) ?? .emoji(value)
        case .emoji(let value): .emoji(value)
        }
        return Reaction(author: ParticipantID(reaction.author), partIndex: reaction.partIndex, kind: kind)
    }

    static func message(_ message: ConversationMessage) -> Message {
        Message(id: MessageID(message.id), conversation: ConversationID(message.conversation), seq: message.seq,
                clientMessageID: IdempotencyKey(message.clientMsgID), author: ParticipantID(message.author),
                parts: message.parts.map(part), createdAt: date(message.createdAt) ?? .distantPast,
                editedAt: date(message.editedAt), retractedAt: date(message.retractedAt),
                reactions: message.reactions.map(reaction))
    }

    static func summary(_ summary: CmuxNextDaemon.ConversationSummary) -> CmuxHomeCore.ConversationSummary {
        CmuxHomeCore.ConversationSummary(
            id: ConversationID(summary.id), owner: summary.owner == "cloud" ? .cloud : .local, title: summary.title,
            participants: summary.participants.map(participant), lastSeq: summary.lastSeq, rev: summary.rev,
            createdAt: date(summary.createdAt) ?? .distantPast, updatedAt: date(summary.updatedAt) ?? .distantPast,
            lastMessage: summary.lastMessage.map(message),
            readCursors: Dictionary(uniqueKeysWithValues: summary.readCursors.map { (ParticipantID($0.key), $0.value) }))
    }

    /// The text parts an op sends. Only text and work parts exist on the local owner.
    static func parts(_ parts: [MessagePart]) -> [ConversationPart] {
        parts.map { part in
            switch part {
            case .text(let text, let mentions):
                return .text(text, runs: mentions.map {
                    ConversationTextRun(start: $0.start, length: $0.length, mention: $0.participant.rawValue)
                })
            case .work(let work):
                return .work(session: work.session, host: work.host, status: work.status.rawValue, preview: work.preview)
            case .approval, .attachment, .linkPreview, .location:
                // The local owner stores only text and work parts.
                return .text(part.plainText, runs: [])
            }
        }
    }

    /// The owner op of a Home intent, or nil when the local owner has no such op.
    static func op(_ op: HomeOp, key: IdempotencyKey) -> (conversation: String, op: ConversationOp)? {
        switch op {
        case .sendMessage(let conversation, let parts):
            return (conversation.rawValue, .send(clientMsgID: key.rawValue, parts: Self.parts(parts), replyTo: nil))
        case .setReadCursor(let conversation, let seq):
            return (conversation.rawValue, .setReadCursor(seq: seq))
        case .addReaction(let message, let conversation, let reaction, let partIndex):
            let kind: ConversationReactionKind = switch reaction {
            case .tapback(let tapback): .tapback(tapback.rawValue)
            case .emoji(let emoji): .emoji(emoji)
            }
            return (conversation.rawValue, .addReaction(messageID: message.rawValue, partIndex: partIndex, kind: kind))
        case .createGroup, .createChief, .startConversation, .invite, .openDirect, .setPinned, .setMuted, .setTyping:
            return nil
        }
    }
}
