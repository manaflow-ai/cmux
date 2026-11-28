import CmuxAgentQuestion
import CmuxHomeCore
import CmuxNextDaemon
import CmuxNextHomeModel
import Foundation

/// The `mapping.*` ops of the shared Home rules (cmux-home-rules `mapping`): the owners' wire rows as
/// Home rows. Requests go as JSON with dates as seconds since 1970, the shape the Rust side reads
/// and answers (`mapping/mod.rs`).
nonisolated extension HomeCoreMapping {
    /// Runs `mapping.<op>` on `input`; on an error (a build without the op, a shape mismatch) asserts
    /// in debug and answers `fallback`, the most conservative row.
    static func mappingRule<In: Encodable, Out: Decodable>(_ op: String, _ input: In, fallback: @autoclosure () -> Out) -> Out {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            let request = String(decoding: try encoder.encode(input), as: UTF8.self)
            let reply = try HomeRules.callJSON("mapping." + op, request)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try decoder.decode(Out.self, from: Data(reply.utf8))
        } catch {
            assertionFailure("mapping.\(op): \(error)")
            return fallback()
        }
    }

    /// The account's ids as the rules name them (`mapping::Identity`).
    struct Identity: Encodable {
        let cloudId: String
        let localId: String
        let displayName: String
        let participantId: String

        init(_ identity: CloudIdentity) {
            cloudId = identity.cloudID
            localId = identity.localID.rawValue
            displayName = identity.displayName
            participantId = identity.participantID
        }
    }

    // MARK: wire rows the daemon types only decode

    /// `ConversationThreadSummary` as the owner sends it.
    struct WireThread: Encodable {
        let root: String
        let reply_count: Int
        let last_reply_seq: UInt64?
        let last_reply_at: String?
        let authors: [String]

        init(_ summary: ConversationThreadSummary) {
            root = summary.root
            reply_count = summary.replyCount
            last_reply_seq = summary.lastReplySeq
            last_reply_at = summary.lastReplyAt
            authors = summary.authors
        }
    }

    /// `ConversationThread` as the owner sends it.
    struct WireThreadPage: Encodable {
        let root: ConversationMessage
        let replies: [ConversationMessage]
        let has_more: Bool
        let thread: WireThread

        init(_ page: ConversationThread) {
            root = page.root
            replies = page.replies
            has_more = page.hasMore
            thread = WireThread(page.thread)
        }
    }

    /// `ConversationSnapshot` and `ConversationHistory` as the owner sends them.
    struct WirePage: Encodable {
        let conversation: CmuxNextDaemon.ConversationSummary?
        let messages: [ConversationMessage]
        let threads: [WireThread]
    }

    /// `StoredConversationAttachment` as the owner sends it.
    struct WireStored: Encodable {
        let hash: String
        let mime_type: String
        let byte_count: Int
        let poster: ConversationDerivedImage?
        let preview: ConversationDerivedImage?

        init(_ stored: StoredConversationAttachment) {
            hash = stored.hash
            mime_type = stored.mimeType
            byte_count = stored.byteCount
            poster = stored.poster
            preview = stored.preview
        }
    }

    // MARK: Home rows the rules answer

    /// A mapped message. The rules answer an owner's question part as `.text("question")` with its
    /// payload in `wireQuestions`; the question type lives in Swift (`CmuxAgentQuestion`), so it is
    /// built here, and a payload it cannot read keeps the text.
    struct MessageRow: Decodable {
        var message: Message

        private struct WireQuestion: Decodable {
            let partIndex: Int
            let payload: JSONValue
        }

        private enum Keys: String, CodingKey { case wireQuestions }

        init(from decoder: any Decoder) throws {
            message = try Message(from: decoder)
            let container = try decoder.container(keyedBy: Keys.self)
            for wire in try container.decodeIfPresent([WireQuestion].self, forKey: .wireQuestions) ?? [] {
                guard message.parts.indices.contains(wire.partIndex),
                      let data = try? JSONEncoder().encode(wire.payload), let json = try? AgentQuestionJSON(data: data),
                      let question = AgentQuestion(conversationPart: json, messageID: message.id.rawValue, partIndex: wire.partIndex)
                else { continue }
                message.parts[wire.partIndex] = .question(question)
            }
        }
    }

    /// A mapped head (its last message as `MessageRow` reads it).
    struct SummaryRow: Decodable {
        var summary: CmuxHomeCore.ConversationSummary

        private enum Keys: String, CodingKey { case lastMessage }

        init(from decoder: any Decoder) throws {
            summary = try CmuxHomeCore.ConversationSummary(from: decoder)
            let container = try decoder.container(keyedBy: Keys.self)
            if let last = try container.decodeIfPresent(MessageRow.self, forKey: .lastMessage) {
                summary.lastMessage = last.message
            }
        }
    }

    /// `ThreadSummary` (not `Codable` in the Home core).
    struct ThreadRow: Decodable {
        let root: MessageID
        let replyCount: Int
        let lastReplySeq: Seq?
        let lastReplyAt: Date?
        let authors: [ParticipantID]

        var thread: ThreadSummary {
            ThreadSummary(root: root, replyCount: replyCount, lastReplySeq: lastReplySeq, lastReplyAt: lastReplyAt, authors: authors)
        }
    }

    struct ThreadPageRow: Decodable {
        let root: MessageRow
        let replies: [MessageRow]
        let hasMore: Bool
        let summary: ThreadRow

        var page: ThreadPage {
            ThreadPage(root: root.message, replies: replies.map(\.message), hasMore: hasMore, summary: summary.thread)
        }
    }

    struct HistoryPageRow: Decodable {
        let messages: [MessageRow]
        let threads: [ThreadRow]

        var page: HistoryPage { HistoryPage(messages: messages.map(\.message), threads: threads.map(\.thread)) }
    }

    struct ConversationPageRow: Decodable {
        let conversation: SummaryRow
        let messages: [MessageRow]
        let threads: [ThreadRow]

        var page: ConversationPage {
            ConversationPage(conversation: conversation.summary, messages: messages.map(\.message), threads: threads.map(\.thread))
        }
    }

    // MARK: conservative rows (an op that failed)

    /// The wire message with its ids, each part as its text, and no date it could misread.
    static func plainMessage(_ wire: ConversationMessage, identity: CloudIdentity? = nil) -> Message {
        let author = identity.map { $0.toHome(wire.author) } ?? ParticipantID(wire.author)
        return Message(id: MessageID(wire.id), conversation: ConversationID(wire.conversation), seq: wire.seq,
                       clientMessageID: IdempotencyKey(wire.clientMsgID), author: author,
                       parts: wire.parts.map { .text($0.plainText) }, createdAt: .distantPast)
    }

    /// The wire head with its ids and counts, and no participants or messages.
    static func plainSummary(_ wire: CmuxNextDaemon.ConversationSummary, owner: CmuxHomeCore.ConversationSummary.Owner) -> CmuxHomeCore.ConversationSummary {
        CmuxHomeCore.ConversationSummary(id: ConversationID(wire.id), owner: owner, title: wire.title, participants: [],
                                         lastSeq: wire.lastSeq, rev: wire.rev, createdAt: .distantPast, updatedAt: .distantPast)
    }

    static func plainThread(_ wire: ConversationThreadSummary) -> ThreadSummary {
        ThreadSummary(root: MessageID(wire.root), replyCount: wire.replyCount, lastReplySeq: wire.lastReplySeq)
    }
}
