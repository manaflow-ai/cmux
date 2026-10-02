public import Foundation

/// Delivery state of a message as the renderer shows it.
public nonisolated enum HomeDelivery: Hashable, Sendable {
    /// Not confirmed by the owner yet (in the intent log).
    case sending
    /// Confirmed by the owner.
    case sent
    /// Rejected or not deliverable; the reason is for diagnostics.
    case failed(String)
    /// Someone else's message.
    case none
}

/// A reaction (tapback or emoji) on one part.
public nonisolated struct HomeReaction: Hashable, Sendable {
    public var authorID: String
    public var partIndex: Int
    /// A tapback name ("love", "like", ...) or an emoji.
    public var kind: String

    public init(authorID: String, partIndex: Int = 0, kind: String) {
        self.authorID = authorID
        self.partIndex = partIndex
        self.kind = kind
    }
}

/// One message as the transcript renders it. Confirmed messages come from the
/// owner's mirror (`seq` set); pending ones from the intent log
/// (`id == "pending:<clientMsgID>"`, `seq == nil`). The row identity is
/// `clientMsgID`, so a pending message settles in place when confirmed.
public nonisolated struct HomeMessage: Hashable, Sendable, Identifiable {
    public var id: String
    public var seq: Int?
    public var clientMsgID: String
    public var authorID: String
    public var parts: [HomePart]
    /// The message this one replies to, by message id.
    public var replyTo: String?
    public var createdAt: Date
    public var delivery: HomeDelivery
    public var reactions: [HomeReaction]
    public var editedAt: Date?
    public var retractedAt: Date?

    public init(id: String, seq: Int?, clientMsgID: String, authorID: String, parts: [HomePart], replyTo: String? = nil,
                createdAt: Date, delivery: HomeDelivery = .none, reactions: [HomeReaction] = [],
                editedAt: Date? = nil, retractedAt: Date? = nil) {
        self.id = id
        self.seq = seq
        self.clientMsgID = clientMsgID
        self.authorID = authorID
        self.parts = parts
        self.replyTo = replyTo
        self.createdAt = createdAt
        self.delivery = delivery
        self.reactions = reactions
        self.editedAt = editedAt
        self.retractedAt = retractedAt
    }

    /// A pending message from the intent log.
    public static func pending(clientMsgID: String, authorID: String, parts: [HomePart], replyTo: String? = nil,
                               createdAt: Date) -> HomeMessage {
        HomeMessage(id: "pending:\(clientMsgID)", seq: nil, clientMsgID: clientMsgID, authorID: authorID, parts: parts,
                    replyTo: replyTo, createdAt: createdAt, delivery: .sending)
    }

    public var isPending: Bool { seq == nil }

    /// Stable row identity across the pending -> confirmed transition.
    public var rowKey: String { clientMsgID.isEmpty ? id : clientMsgID }

    /// Changes whenever the drawn content changes (edit, retraction): part of
    /// the measurement cache key.
    public var contentVersion: Int {
        if retractedAt != nil { return -1 }
        guard let editedAt else { return 0 }
        return Int(editedAt.timeIntervalSinceReferenceDate * 1000) & 0x7fff_ffff
    }
}
