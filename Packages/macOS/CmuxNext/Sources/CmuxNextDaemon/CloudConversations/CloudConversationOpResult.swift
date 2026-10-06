import Foundation


/// `cloud-conversation-op` data. `value` is the owner's value verbatim;
/// `rev`, `seq` and `change` are lifted from it when present. `transaction`,
/// `stream` and `sequence` are the cloud request-settled barrier.
public struct CloudConversationOpResult: Decodable, Sendable, Equatable {
    /// The owner's answer to an address peer's invite in `dm.open`.
    public struct InviteOutcome: Decodable, Sendable, Equatable {
        public var ok: Bool
        public var code: String?
        public init(ok: Bool, code: String? = nil) {
            self.ok = ok
            self.code = code
        }
    }

    public var value: JSONValue
    public var rev: UInt64?
    public var seq: UInt64?
    public var change: ConversationChange?
    public var replayed: Bool
    public var transaction: String
    public var stream: String
    public var sequence: UInt64
    /// `value.conversation` of `dm.open` and `conversation.create`.
    public var conversation: ConversationSummary?
    /// `value.invite` of `dm.open` with an address peer.
    public var invite: InviteOutcome?

    public init(value: JSONValue = .null, rev: UInt64? = nil, seq: UInt64? = nil, change: ConversationChange? = nil,
                replayed: Bool = false, transaction: String = "", stream: String = "", sequence: UInt64 = 0,
                conversation: ConversationSummary? = nil, invite: InviteOutcome? = nil) {
        self.value = value
        self.rev = rev
        self.seq = seq
        self.change = change
        self.replayed = replayed
        self.transaction = transaction
        self.stream = stream
        self.sequence = sequence
        self.conversation = conversation
        self.invite = invite
    }

    private struct ValueFields: Decodable {
        var conversation: ConversationSummary?
        var invite: InviteOutcome?
    }

    enum CodingKeys: String, CodingKey { case value, rev, seq, change, replayed, transaction, stream, sequence }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = try c.decodeIfPresent(JSONValue.self, forKey: .value) ?? .null
        rev = try c.decodeIfPresent(UInt64.self, forKey: .rev)
        seq = try c.decodeIfPresent(UInt64.self, forKey: .seq)
        change = try? c.decodeIfPresent(ConversationChange.self, forKey: .change)
        replayed = try c.decodeIfPresent(Bool.self, forKey: .replayed) ?? false
        transaction = try c.decodeIfPresent(String.self, forKey: .transaction) ?? ""
        stream = try c.decodeIfPresent(String.self, forKey: .stream) ?? ""
        sequence = try c.decodeIfPresent(UInt64.self, forKey: .sequence) ?? 0
        let fields = try? c.decodeIfPresent(ValueFields.self, forKey: .value)
        conversation = fields?.conversation
        invite = fields?.invite
    }
}
