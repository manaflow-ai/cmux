import Foundation

/// A conversation's head as its owner reports it.
public struct ConversationSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// `local` (this Mac's daemon) or `cloud` (a ConversationDO).
    public var owner: String
    public var title: String
    public var participants: [ConversationParticipant]
    public var lastSeq: UInt64
    /// Increases by one per committed op; a gap means the mirror missed one.
    public var rev: UInt64
    public var createdAt: String
    public var updatedAt: String
    public var lastMessage: ConversationMessage?
    public var readCursors: [String: UInt64]

    public init(id: String, owner: String = "local", title: String, participants: [ConversationParticipant], lastSeq: UInt64,
                rev: UInt64, createdAt: String, updatedAt: String, lastMessage: ConversationMessage? = nil,
                readCursors: [String: UInt64] = [:]) {
        self.id = id
        self.owner = owner
        self.title = title
        self.participants = participants
        self.lastSeq = lastSeq
        self.rev = rev
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastMessage = lastMessage
        self.readCursors = readCursors
    }

    enum CodingKeys: String, CodingKey {
        case id, owner, title, participants, rev
        case lastSeq = "last_seq"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastMessage = "last_message"
        case readCursors = "read_cursors"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        owner = try c.decodeIfPresent(String.self, forKey: .owner) ?? "local"
        title = try c.decode(String.self, forKey: .title)
        participants = try c.decode([ConversationParticipant].self, forKey: .participants)
        lastSeq = try c.decode(UInt64.self, forKey: .lastSeq)
        rev = try c.decode(UInt64.self, forKey: .rev)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        updatedAt = try c.decode(String.self, forKey: .updatedAt)
        lastMessage = try c.decodeIfPresent(ConversationMessage.self, forKey: .lastMessage)
        readCursors = try c.decodeIfPresent([String: UInt64].self, forKey: .readCursors) ?? [:]
    }

    /// Messages after `participant`'s read cursor.
    public func unreadCount(for participant: String) -> UInt64 {
        lastSeq - min(lastSeq, readCursors[participant] ?? 0)
    }
}
