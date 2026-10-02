public import Foundation

/// One content part of a message. Mirrors the conversation owner's `Part`.
public enum MessagePart: Hashable, Sendable, Codable {
    /// Plain text; `mentions` are UTF-16 ranges that name a participant.
    case text(String, mentions: [Mention] = [])
    /// A reference to an agent session the Chief started (acpmux session).
    case work(WorkRef)
    /// A question an agent asks a human; answered with `approval.decide`.
    case approval(ApprovalRef)

    public var plainText: String {
        switch self {
        case .text(let text, _): text
        case .work(let work): work.preview ?? work.title
        case .approval(let approval): approval.prompt
        }
    }
}

public struct Mention: Hashable, Sendable, Codable {
    public var start: Int
    public var length: Int
    public var participant: ParticipantID

    public init(start: Int, length: Int, participant: ParticipantID) {
        self.start = start
        self.length = length
        self.participant = participant
    }
}

public struct WorkRef: Hashable, Sendable, Codable {
    public enum Status: String, Hashable, Sendable, Codable { case running, waiting, done, failed }
    public var session: String
    public var host: String?
    public var title: String
    public var status: Status
    public var preview: String?

    public init(session: String, host: String? = nil, title: String, status: Status, preview: String? = nil) {
        self.session = session
        self.host = host
        self.title = title
        self.status = status
        self.preview = preview
    }
}

public struct ApprovalRef: Hashable, Sendable, Codable {
    public var request: String
    public var prompt: String
    public var options: [String]
    public var decided: String?

    public init(request: String, prompt: String, options: [String], decided: String? = nil) {
        self.request = request
        self.prompt = prompt
        self.options = options
        self.decided = decided
    }
}

public struct Reaction: Hashable, Sendable, Codable {
    public enum Kind: Hashable, Sendable, Codable {
        case tapback(Tapback)
        case emoji(String)
    }

    public enum Tapback: String, Hashable, Sendable, Codable, CaseIterable {
        case love, like, dislike, laugh, emphasize, question
    }

    public var author: ParticipantID
    public var partIndex: Int
    public var kind: Kind

    public init(author: ParticipantID, partIndex: Int, kind: Kind) {
        self.author = author
        self.partIndex = partIndex
        self.kind = kind
    }
}

/// A committed message. Only the owner creates these; clients render them
/// from the mirror.
public struct Message: Hashable, Sendable, Codable, Identifiable {
    public let id: MessageID
    public let conversation: ConversationID
    public let seq: Seq
    public let clientMessageID: IdempotencyKey
    public let author: ParticipantID
    public var parts: [MessagePart]
    public let createdAt: Date
    public var editedAt: Date?
    public var retractedAt: Date?
    public var reactions: [Reaction]

    public init(
        id: MessageID,
        conversation: ConversationID,
        seq: Seq,
        clientMessageID: IdempotencyKey,
        author: ParticipantID,
        parts: [MessagePart],
        createdAt: Date,
        editedAt: Date? = nil,
        retractedAt: Date? = nil,
        reactions: [Reaction] = []
    ) {
        self.id = id
        self.conversation = conversation
        self.seq = seq
        self.clientMessageID = clientMessageID
        self.author = author
        self.parts = parts
        self.createdAt = createdAt
        self.editedAt = editedAt
        self.retractedAt = retractedAt
        self.reactions = reactions
    }

    public var plainText: String { parts.map(\.plainText).joined(separator: "\n") }
    public var isRetracted: Bool { retractedAt != nil }
}
