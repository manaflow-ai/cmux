import Foundation

/// A person (or agent) taking part in a conversation.
public struct ConversationParticipant: Sendable, Hashable, Identifiable {
    public let id: String
    public var name: String
    public var initials: String
    /// `#RRGGBB`, used for the avatar fill.
    public var colorHex: String
    public var isMe: Bool

    public init(id: String, name: String, initials: String, colorHex: String, isMe: Bool) {
        self.id = id
        self.name = name
        self.initials = initials
        self.colorHex = colorHex
        self.isMe = isMe
    }
}

public enum ConversationKind: String, Sendable, Hashable {
    case group
    case direct
}

public struct ConversationInfo: Sendable, Hashable {
    public let id: String
    public var title: String
    public var kind: ConversationKind
    public var participants: [ConversationParticipant]

    public init(id: String, title: String, kind: ConversationKind, participants: [ConversationParticipant]) {
        self.id = id
        self.title = title
        self.kind = kind
        self.participants = participants
    }

    public func participant(_ id: String) -> ConversationParticipant? {
        participants.first { $0.id == id }
    }
}

/// The six iMessage tapbacks.
public enum ConversationReaction: String, Sendable, Hashable, CaseIterable {
    case heart
    case thumbsup
    case thumbsdown
    case haha
    case exclamation
    case question
}

public struct ConversationReactionMark: Sendable, Hashable {
    public var participantID: String
    public var reaction: ConversationReaction

    public init(participantID: String, reaction: ConversationReaction) {
        self.participantID = participantID
        self.reaction = reaction
    }
}

public struct ConversationAttachment: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case image
    }

    public let id: String
    public var kind: Kind
    public var width: Int
    public var height: Int
    /// Remote location. Nil while a local attachment has not finished uploading.
    public var url: URL?
    /// Bytes picked locally, kept so the sender's row renders before upload.
    public var localData: Data?

    public init(id: String, kind: Kind, width: Int, height: Int, url: URL?, localData: Data? = nil) {
        self.id = id
        self.kind = kind
        self.width = width
        self.height = height
        self.url = url
        self.localData = localData
    }

    public var aspectRatio: Double {
        guard width > 0, height > 0 else { return 4.0 / 3.0 }
        return Double(width) / Double(height)
    }
}

/// Delivery of a message I sent. Messages from others carry no delivery.
public enum ConversationDelivery: Sendable, Hashable {
    case sending
    case sent
    case delivered
    case read(Date?)
    case failed(String)

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

public struct ConversationMessage: Sendable, Hashable, Identifiable {
    /// Server id, or `local:<clientMessageID>` before the server acknowledged.
    public var id: String
    /// Server order key. Nil until acknowledged.
    public var seq: Int?
    public var clientMessageID: String?
    public var senderID: String
    public var sentAt: Date
    public var text: String
    public var replyToID: String?
    public var replyCount: Int
    public var editedAt: Date?
    public var reactions: [ConversationReactionMark]
    public var attachments: [ConversationAttachment]
    public var delivery: ConversationDelivery?
    /// A Messages poll carried by this message (`text` holds its question).
    public var poll: ConversationPoll?

    public init(
        id: String,
        seq: Int?,
        clientMessageID: String?,
        senderID: String,
        sentAt: Date,
        text: String,
        replyToID: String? = nil,
        replyCount: Int = 0,
        editedAt: Date? = nil,
        reactions: [ConversationReactionMark] = [],
        attachments: [ConversationAttachment] = [],
        delivery: ConversationDelivery? = nil,
        poll: ConversationPoll? = nil
    ) {
        self.id = id
        self.seq = seq
        self.clientMessageID = clientMessageID
        self.senderID = senderID
        self.sentAt = sentAt
        self.text = text
        self.replyToID = replyToID
        self.replyCount = replyCount
        self.editedAt = editedAt
        self.reactions = reactions
        self.attachments = attachments
        self.delivery = delivery
        self.poll = poll
    }

    /// Identity that survives the pending to acknowledged transition, so the
    /// row a sender sees never re-inserts when the server echo arrives.
    public var rowID: String { clientMessageID.map { "c:\($0)" } ?? "s:\(id)" }
}

public struct ConversationHistoryPage: Sendable {
    public var messages: [ConversationMessage]
    public var hasMore: Bool

    public init(messages: [ConversationMessage], hasMore: Bool) {
        self.messages = messages
        self.hasMore = hasMore
    }
}

public struct ConversationOutgoingDraft: Sendable {
    public var clientMessageID: String
    public var text: String
    public var replyToID: String?
    public var attachmentIDs: [String]
    /// Set when the message creates a poll.
    public var poll: ConversationPollDraft?

    public init(clientMessageID: String, text: String, replyToID: String?, attachmentIDs: [String], poll: ConversationPollDraft? = nil) {
        self.clientMessageID = clientMessageID
        self.text = text
        self.replyToID = replyToID
        self.attachmentIDs = attachmentIDs
        self.poll = poll
    }
}

// MARK: - Polls

/// One choice of a poll. Anyone in the conversation may add choices.
public struct ConversationPollOption: Sendable, Hashable, Identifiable {
    public let id: String
    public var text: String
    /// Who added the choice; nil for the creator's original choices.
    public var addedByID: String?

    public init(id: String, text: String, addedByID: String? = nil) {
        self.id = id
        self.text = text
        self.addedByID = addedByID
    }
}

/// One participant's vote for one choice. Messages polls are multi-select:
/// a participant may vote for any number of choices, and tapping a choice
/// again takes that vote back.
public struct ConversationPollVote: Sendable, Hashable {
    public var participantID: String
    public var optionID: String
    public var votedAt: Date?

    public init(participantID: String, optionID: String, votedAt: Date? = nil) {
        self.participantID = participantID
        self.optionID = optionID
        self.votedAt = votedAt
    }
}

public struct ConversationPoll: Sendable, Hashable {
    public var question: String
    public var options: [ConversationPollOption]
    public var votes: [ConversationPollVote]

    /// Messages allows up to 12 choices.
    public static let maxOptions = 12
    /// The leading choice's bar fills this fraction of the row
    /// (ChatKit `pollsWinnerWidthPercentage`); others scale to it.
    public static let winnerWidthFraction = 0.95

    public init(question: String, options: [ConversationPollOption], votes: [ConversationPollVote] = []) {
        self.question = question
        self.options = options
        self.votes = votes
    }

    public func option(_ id: String) -> ConversationPollOption? {
        options.first { $0.id == id }
    }

    /// Voters for a choice, oldest vote first.
    public func voterIDs(for optionID: String) -> [String] {
        votes.filter { $0.optionID == optionID }.map(\.participantID)
    }

    public func voteCount(for optionID: String) -> Int {
        votes.reduce(0) { $0 + ($1.optionID == optionID ? 1 : 0) }
    }

    public func hasVote(participantID: String, optionID: String) -> Bool {
        votes.contains { $0.participantID == participantID && $0.optionID == optionID }
    }

    public var leadingVoteCount: Int {
        options.map { voteCount(for: $0.id) }.max() ?? 0
    }

    /// Fraction of the row the vote bar fills, relative to the leading choice.
    public func barFraction(for optionID: String) -> Double {
        let leading = leadingVoteCount
        guard leading > 0 else { return 0 }
        return Double(voteCount(for: optionID)) / Double(leading) * Self.winnerWidthFraction
    }

    /// Participants (in the given order) who have not voted for anything.
    public func nonVoterIDs(among participantIDs: [String]) -> [String] {
        let voted = Set(votes.map(\.participantID))
        return participantIDs.filter { !voted.contains($0) }
    }

    public mutating func setVote(participantID: String, optionID: String, selected: Bool, at date: Date? = nil) {
        let has = hasVote(participantID: participantID, optionID: optionID)
        if selected, !has {
            votes.append(ConversationPollVote(participantID: participantID, optionID: optionID, votedAt: date))
        } else if !selected, has {
            votes.removeAll { $0.participantID == participantID && $0.optionID == optionID }
        }
    }
}

/// What the poll composer sends.
public struct ConversationPollDraft: Sendable, Hashable {
    public var question: String
    public var options: [String]

    public init(question: String, options: [String]) {
        self.question = question
        self.options = options
    }
}

/// A vote the backend refused; Messages shows "Poll vote failed." with Try Again.
public struct ConversationPollVoteFailure: Sendable, Hashable {
    public var optionID: String
    public var selected: Bool

    public init(optionID: String, selected: Bool) {
        self.optionID = optionID
        self.selected = selected
    }
}
