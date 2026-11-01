public import Foundation

/// Persisted messages exchanged with agents during one Chief run, independent of its live reply.
public struct HomeAgentRun: Hashable, Sendable {
    /// A message step; revisions replace the same step without adding another row.
    public struct Message: Hashable, Sendable {
        public var id: String
        public var sequence: UInt64
        public var revision: UInt64
        public var peer: String
        public var outgoing: Bool
        public var text: String
        public var date: Date

        public init(id: String, sequence: UInt64, revision: UInt64, peer: String, outgoing: Bool, text: String, date: Date) {
            self.id = id
            self.sequence = sequence
            self.revision = revision
            self.peer = peer
            self.outgoing = outgoing
            self.text = text
            self.date = date
        }
    }

    public var revision: UInt64
    public var conversation: ConversationID
    public var id: String
    public var author: ParticipantID
    public var turn: IdempotencyKey?
    public var answers: [MessageID]
    public var threadRoot: MessageID?
    public var messages: [Message]

    public init(conversation: ConversationID, id: String, author: ParticipantID, turn: IdempotencyKey?,
                answers: [MessageID], threadRoot: MessageID? = nil, revision: UInt64 = 0, messages: [Message]) {
        self.revision = revision
        self.conversation = conversation
        self.id = id
        self.author = author
        self.turn = turn
        self.answers = answers
        self.threadRoot = threadRoot
        self.messages = messages
    }
}
