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
        delivery: ConversationDelivery? = nil
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

    public init(clientMessageID: String, text: String, replyToID: String?, attachmentIDs: [String]) {
        self.clientMessageID = clientMessageID
        self.text = text
        self.replyToID = replyToID
        self.attachmentIDs = attachmentIDs
    }
}
