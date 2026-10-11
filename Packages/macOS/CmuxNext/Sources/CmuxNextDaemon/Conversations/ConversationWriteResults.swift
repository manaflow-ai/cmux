import Foundation

/// `conversation-create` data.
public struct ConversationCreated: Decodable, Sendable, Equatable {
    public var conversation: ConversationSummary
    /// True when the key was seen before and nothing changed.
    public var replayed: Bool

    enum CodingKeys: String, CodingKey { case conversation, replayed }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversation = try c.decode(ConversationSummary.self, forKey: .conversation)
        replayed = try c.decodeIfPresent(Bool.self, forKey: .replayed) ?? false
    }
}

/// `conversation-op` data: the committed revision and the change it made.
public struct ConversationOpResult: Decodable, Sendable, Equatable {
    public var transaction: ClientTransactionID?
    public var rev: UInt64
    public var seq: UInt64?
    public var replayed: Bool
    public var change: ConversationChange

    public init(transaction: ClientTransactionID?, rev: UInt64, seq: UInt64?, replayed: Bool, change: ConversationChange) {
        self.transaction = transaction
        self.rev = rev
        self.seq = seq
        self.replayed = replayed
        self.change = change
    }

    enum CodingKeys: String, CodingKey { case transaction, rev, seq, replayed, change }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transaction = try c.decodeIfPresent(ClientTransactionID.self, forKey: .transaction)
        rev = try c.decode(UInt64.self, forKey: .rev)
        seq = try c.decodeIfPresent(UInt64.self, forKey: .seq)
        replayed = try c.decodeIfPresent(Bool.self, forKey: .replayed) ?? false
        change = try c.decode(ConversationChange.self, forKey: .change)
    }
}
