import Foundation

/// The mock owner's demo data, for previews, renderer tests and benchmarks:
/// one Chief pinned first, two subchiefs, three people, two groups and one
/// invited person; the Chief's history is generated from its seq on read.
public struct HomeDemoData: Sendable {
    public let me: Participant
    public let chief: Participant
    public let people: [Participant]
    public let conversations: [ConversationSummary]
    /// Stored messages per conversation (the generated Chief history is not included).
    public let messages: [ConversationID: [Message]]

    public init(now: Date = Date(), chiefHistory: Int = 300) {
        let seed = MockHomeSeed.make(now: now, chiefHistory: chiefHistory)
        me = seed.me
        chief = seed.chief
        people = seed.people
        conversations = seed.conversations
        messages = seed.messages
    }
}
