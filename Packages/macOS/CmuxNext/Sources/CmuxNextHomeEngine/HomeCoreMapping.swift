import CmuxAgentQuestion
public import CmuxHomeCore
public import CmuxNextDaemon
import Foundation

/// The local conversation owner's wire types (CmuxNextDaemon) as the shared
/// Home core's types (CmuxHomeCore, plans/cmux-next/home-mac.md). Pure; the
/// owner's ids and seqs pass through unchanged.
public nonisolated enum HomeCoreMapping {
    nonisolated(unsafe) private static let dates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()  // ISO8601DateFormatter is thread safe.

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        return dates.date(from: text)
    }

    /// The local mux is the chief (N1: "Chief"); `mapping.participant`.
    public static func participant(_ participant: ConversationParticipant) -> Participant {
        struct Request: Encodable { let participant: ConversationParticipant; let chiefName: String }
        struct Reply: Decodable { let participant: Participant }
        return HomeCoreMapping.mappingRule("participant", Request(participant: participant, chiefName: HomeStrings.chiefName),
                                            fallback: Reply(participant: Participant(id: ParticipantID(participant.id), kind: .human,
                                                                                     displayName: participant.displayName))).participant
    }

    /// A Home attachment ref as the owner's attachment part.
    static func attachment(_ ref: AttachmentRef) -> ConversationAttachment {
        let derived = { (image: AttachmentDerivedImage) in
            ConversationDerivedImage(hash: image.hash, mimeType: image.mimeType, byteCount: image.byteCount)
        }
        return ConversationAttachment(hash: ref.hash, name: ref.name, mimeType: ref.mimeType, byteCount: ref.byteCount,
                                      width: ref.width, height: ref.height, durationMs: ref.durationMs,
                                      poster: ref.poster.map(derived), preview: ref.preview.map(derived))
    }

    /// The ref an owner stored for an upload (`mapping.refStoredAs`): the owner keeps the first
    /// record of a hash, so its type, size and derived images win.
    static func ref(_ ref: AttachmentRef, storedAs stored: StoredConversationAttachment) -> AttachmentRef {
        struct Request: Encodable {
            let ref: AttachmentRef
            let stored: HomeCoreMapping.WireStored
        }
        struct Reply: Decodable { let ref: AttachmentRef }
        return HomeCoreMapping.mappingRule("refStoredAs", Request(ref: ref, stored: .init(stored)), fallback: Reply(ref: ref)).ref
    }

    /// `mapping.message` (`identity`: a cloud owner's row, its account's id as Home's).
    static func message(_ message: ConversationMessage, identity: CloudIdentity? = nil) -> Message {
        struct Request: Encodable {
            let message: ConversationMessage
            let identity: HomeCoreMapping.Identity?
        }
        struct Reply: Decodable { let message: HomeCoreMapping.MessageRow }
        return HomeCoreMapping.mappingRule("message", Request(message: message, identity: identity.map(HomeCoreMapping.Identity.init)),
                                            fallback: Reply?.none)?.message.message
            ?? HomeCoreMapping.plainMessage(message, identity: identity)
    }

    /// A local head (`mapping.summary`).
    static func summary(_ summary: CmuxNextDaemon.ConversationSummary) -> CmuxHomeCore.ConversationSummary {
        struct Request: Encodable { let summary: CmuxNextDaemon.ConversationSummary; let chiefName: String }
        struct Reply: Decodable { let summary: HomeCoreMapping.SummaryRow }
        return HomeCoreMapping.mappingRule("summary", Request(summary: summary, chiefName: HomeStrings.chiefName),
                                            fallback: Reply?.none)?.summary.summary
            ?? HomeCoreMapping.plainSummary(summary, owner: summary.owner == "cloud" ? .cloud : .local)
    }

    /// The parts an op sends (`mapping.parts`). The local owner stores text, work, attachment
    /// (`local-attachments-v1`) and link preview parts; other kinds go as their text.
    static func parts(_ parts: [MessagePart]) -> [ConversationPart] {
        struct Request: Encodable { let parts: [MessagePart]; let plainTexts: [String?] }
        struct Reply: Decodable { let parts: [ConversationPart] }
        return HomeCoreMapping.mappingRule("parts", Request(parts: parts, plainTexts: plainTexts(parts)),
                                            fallback: Reply(parts: parts.map { .text($0.plainText, runs: []) })).parts
    }

    /// The text an approval, location or question part goes as (Swift's `plainText`; the rules
    /// have no question transcript).
    static func plainTexts(_ parts: [MessagePart]) -> [String?] {
        parts.map { part in
            switch part {
            case .approval, .location, .question: part.plainText
            case .text, .work, .attachment, .linkPreview: nil
            }
        }
    }

    static func reactionKind(_ reaction: Reaction.Kind) -> ConversationReactionKind {
        switch reaction {
        case .tapback(let tapback): .tapback(tapback.rawValue)
        case .emoji(let emoji): .emoji(emoji)
        }
    }

    /// The owner op of a Home intent, or nil when the local owner has no such op.
    static func op(_ op: HomeOp, key: IdempotencyKey) -> (conversation: String, op: ConversationOp)? {
        switch op {
        case .sendMessage(let conversation, let parts, let threadRoot, let parent):
            // `thread_root` is the thread; `reply_to` the message answered (conversation-tree-v1:
            // any depth), the root's first part without a parent, which also keeps the thread on a
            // daemon from before threads (it drops `thread_root`).
            return (conversation.rawValue, .send(clientMsgID: key.rawValue, parts: Self.parts(parts),
                                                 replyTo: threadRoot.map { ConversationPartRef(messageID: (parent ?? $0).rawValue, partIndex: 0) },
                                                 threadRoot: threadRoot?.rawValue))
        case .editMessage(let message, let conversation, let parts):
            return (conversation.rawValue, .edit(messageID: message.rawValue, parts: Self.parts(parts)))
        case .retractMessage(let message, let conversation):
            return (conversation.rawValue, .retract(messageID: message.rawValue))
        case .setReadCursor(let conversation, let seq):
            return (conversation.rawValue, .setReadCursor(seq: seq))
        case .addReaction(let message, let conversation, let reaction, let partIndex):
            return (conversation.rawValue, .addReaction(messageID: message.rawValue, partIndex: partIndex, kind: Self.reactionKind(reaction)))
        case .removeReaction(let message, let conversation, let reaction, let partIndex):
            return (conversation.rawValue, .removeReaction(messageID: message.rawValue, partIndex: partIndex, kind: Self.reactionKind(reaction)))
        case .answerQuestion(let message, let conversation, let partIndex, let answer):
            guard let data = try? answer.conversationAnswer.data(),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
            return (conversation.rawValue, .answerQuestion(messageID: message.rawValue, partIndex: partIndex, answer: value))
        case .updateThread(let conversation, let root, let title, let status, let owner):
            return (conversation.rawValue, .updateThread(root: root.rawValue, title: title, status: status?.rawValue, owner: owner))
        case .renameConversation(let conversation, let title):
            return (conversation.rawValue, .setTitle(title.trimmingCharacters(in: .whitespacesAndNewlines)))
        case .createGroup, .createChief, .startConversation, .invite, .openDirect, .setPinned, .setMuted, .setTyping,
             .addParticipants, .removeParticipant, .setChiefReplies:
            // The local owner has no settings op (its wake rule is fixed: home.md section 5).
            // The local owner has no participants.remove, and its participants.add needs the
            // person's record (names), which only the cloud's directory holds.
            return nil
        }
    }
}
