import Foundation


/// `cloud-conversation-snapshot` data: the head (`rev`) and the newest
/// messages, ascending; `seq` is the owner stream's sequence.
public struct CloudConversationSnapshot: Decodable, Sendable, Equatable {
    public var conversation: ConversationSummary
    public var messages: [ConversationMessage]
    public var rev: UInt64
    public var seq: UInt64

    public init(conversation: ConversationSummary, messages: [ConversationMessage], rev: UInt64, seq: UInt64) {
        self.conversation = conversation
        self.messages = messages
        self.rev = rev
        self.seq = seq
    }
}
