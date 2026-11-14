/// What ``HomeDirectory/createChannel(title:chiefName:people:)`` made: the channel's own Chief, the
/// channel's conversation and one result per person invited, in the order given.
public nonisolated struct HomeChannelCreation: Hashable, Sendable {
    /// One person's invite: `ok`, or the owner's refusal `code` (`not_reachable`, `invite_limit`, …).
    public struct Invited: Hashable, Sendable {
        /// The person as given (``HomeChannelPerson/label``).
        public var who: String
        /// The owner took the invite or the add.
        public var ok: Bool
        /// The owner's refusal code when `ok` is false.
        public var code: String?

        /// - Parameters:
        ///   - who: The person as given.
        ///   - ok: The owner took it.
        ///   - code: The refusal code, when refused.
        public init(who: String, ok: Bool, code: String? = nil) {
            self.who = who
            self.ok = ok
            self.code = code
        }
    }

    /// The channel's own Chief (its main conversation is the channel).
    public var chief: HomeChiefRecord
    /// The channel's conversation id.
    public var conversation: String
    /// One result per person, in order.
    public var invited: [Invited]

    /// - Parameters:
    ///   - chief: The channel's Chief record.
    ///   - conversation: The channel's conversation id.
    ///   - invited: One result per person.
    public init(chief: HomeChiefRecord, conversation: String, invited: [Invited]) {
        self.chief = chief
        self.conversation = conversation
        self.invited = invited
    }
}
