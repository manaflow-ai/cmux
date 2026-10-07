import Foundation

/// A person (or agent) taking part in a conversation.
public struct ConversationParticipant: Sendable, Hashable, Identifiable {
    public let id: String
    public var name: String
    public var initials: String
    /// `#RRGGBB`, used for the avatar fill.
    public var colorHex: String
    public var isMe: Bool
    /// A Focus is on and shared: Messages delivers quietly and shows
    /// "<Name> has notifications silenced".
    public var notificationsSilenced: Bool
    /// Left (or was removed from) the group. Their messages keep their name.
    public var hasLeft: Bool

    public init(id: String, name: String, initials: String, colorHex: String, isMe: Bool, notificationsSilenced: Bool = false, hasLeft: Bool = false) {
        self.id = id
        self.name = name
        self.initials = initials
        self.colorHex = colorHex
        self.isMe = isMe
        self.notificationsSilenced = notificationsSilenced
        self.hasLeft = hasLeft
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
    /// Pin, Hide Alerts, Mark as Unread and Delete state in the conversation list.
    public var listState: ConversationListState
    /// The shared conversation background (iOS 26 / macOS 26). Nil is none.
    public var background: ConversationBackground?

    public init(
        id: String,
        title: String,
        kind: ConversationKind,
        participants: [ConversationParticipant],
        listState: ConversationListState = ConversationListState(),
        background: ConversationBackground? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.participants = participants
        self.listState = listState
        self.background = background
    }

    public func participant(_ id: String) -> ConversationParticipant? {
        participants.first { $0.id == id }
    }
}

/// An iMessage tapback: one of the six classics, or (iOS 18+) any single
/// emoji picked through "Add custom emoji reaction".
public enum ConversationReaction: Sendable, Hashable, CaseIterable, RawRepresentable {
    case heart
    case thumbsup
    case thumbsdown
    case haha
    case exclamation
    case question
    /// A custom emoji tapback. Holds exactly one emoji (see `isSingleEmoji`).
    case emoji(String)

    /// The six classic tapbacks, in picker order. Custom emoji are open-ended,
    /// so they are not listed.
    public static let allCases: [ConversationReaction] = [.heart, .thumbsup, .thumbsdown, .haha, .exclamation, .question]

    /// The wire value: the classic's name, or the emoji itself.
    public var rawValue: String {
        switch self {
        case .heart: return "heart"
        case .thumbsup: return "thumbsup"
        case .thumbsdown: return "thumbsdown"
        case .haha: return "haha"
        case .exclamation: return "exclamation"
        case .question: return "question"
        case .emoji(let emoji): return emoji
        }
    }

    /// A classic's name, or a single emoji; anything else is unknown (nil).
    public init?(rawValue: String) {
        if let classic = Self.allCases.first(where: { $0.rawValue == rawValue }) {
            self = classic
        } else if Self.isSingleEmoji(rawValue) {
            self = .emoji(rawValue)
        } else {
            return nil
        }
    }

    /// The custom emoji, or nil for a classic tapback.
    public var emoji: String? {
        if case .emoji(let emoji) = self { return emoji }
        return nil
    }

    /// Whether `text` is exactly one emoji as the emoji keyboard types it:
    /// one grapheme that renders as emoji (presentation-default, or made so by
    /// a variation selector, skin tone, keycap or ZWJ sequence).
    public static func isSingleEmoji(_ text: String) -> Bool {
        guard text.count == 1, let first = text.unicodeScalars.first, first.properties.isEmoji else { return false }
        if first.properties.isEmojiPresentation { return true }
        // Text-default (digits, ©, ❤): emoji only with a selector, keycap, skin tone or ZWJ.
        return text.unicodeScalars.dropFirst().contains {
            $0 == "\u{FE0F}" || $0 == "\u{20E3}" || $0 == "\u{200D}" || $0.properties.isEmojiModifier
        }
    }
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
        case audio
    }

    public let id: String
    public var kind: Kind
    public var width: Int
    public var height: Int
    /// Remote location. Nil while a local attachment has not finished uploading.
    public var url: URL?
    /// Bytes picked locally, kept so the sender's row renders before upload.
    public var localData: Data?
    /// Audio only: the recording's metadata. See `ConversationAudioInfo`.
    public var audio: ConversationAudioInfo?

    public init(id: String, kind: Kind, width: Int, height: Int, url: URL?, localData: Data? = nil, audio: ConversationAudioInfo? = nil) {
        self.id = id
        self.kind = kind
        self.width = width
        self.height = height
        self.url = url
        self.localData = localData
        self.audio = audio
    }

    public var aspectRatio: Double {
        guard width > 0, height > 0 else { return 4.0 / 3.0 }
        return Double(width) / Double(height)
    }
}

/// An audio message's recording details, as Messages shows them in the bubble.
public struct ConversationAudioInfo: Sendable, Hashable {
    public var duration: TimeInterval
    /// Peak levels in 0...1, evenly spaced over the recording.
    public var waveform: [Float]
    /// Speech-to-text of the recording (iOS 17+ shows it under the waveform).
    public var transcript: String?
    /// When this device deletes the recording unless it is kept. Nil means kept
    /// (or never set to expire).
    public var expiresAt: Date?
    /// The reader tapped Keep.
    public var isKept: Bool

    public init(duration: TimeInterval, waveform: [Float], transcript: String? = nil, expiresAt: Date? = nil, isKept: Bool = false) {
        self.duration = duration
        self.waveform = waveform
        self.transcript = transcript
        self.expiresAt = expiresAt
        self.isKept = isKept
    }

    /// `count` levels resampled from `waveform` by taking each bucket's peak.
    public func levels(count: Int) -> [Float] {
        Self.resample(waveform, count: count)
    }

    public static func resample(_ source: [Float], count: Int) -> [Float] {
        guard count > 0 else { return [] }
        guard !source.isEmpty else { return Array(repeating: 0, count: count) }
        return (0..<count).map { index in
            let start = index * source.count / count
            let end = max(start + 1, (index + 1) * source.count / count)
            return source[start..<min(end, source.count)].max() ?? 0
        }
    }
}

extension ConversationMessage {
    /// The audio attachment of an audio message (Messages sends them alone).
    public var audioAttachment: ConversationAttachment? {
        attachments.first { $0.kind == .audio }
    }
}

/// Messages "send with effect". Bubble effects animate the message's own
/// bubble; screen effects play a full-screen animation over the transcript.
public enum ConversationMessageEffect: String, Sendable, Hashable, CaseIterable {
    case slam
    case loud
    case gentle
    case invisibleInk
    case echo
    case spotlight
    case balloons
    case confetti
    case love
    case lasers
    case fireworks
    case celebration

    public enum Kind: Sendable, Hashable {
        case bubble
        case screen
    }

    public var kind: Kind {
        switch self {
        case .slam, .loud, .gentle, .invisibleInk: return .bubble
        default: return .screen
        }
    }

    /// Whether the message keeps a "Replay" control. Invisible Ink stays
    /// covered until touched instead.
    public var isReplayable: Bool { self != .invisibleInk }

    /// Picker order, as Messages lists them.
    public static let bubbleEffects: [ConversationMessageEffect] = [.slam, .loud, .gentle, .invisibleInk]
    public static let screenEffects: [ConversationMessageEffect] = [
        .echo, .spotlight, .balloons, .confetti, .love, .lasers, .fireworks, .celebration,
    ]
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
    /// How many times the sender edited it (Messages allows five).
    public var editCount: Int
    /// Set when the sender took the message back (Undo Send). The row shows
    /// a notice in its place; text and attachments are gone.
    public var unsentAt: Date?
    public var reactions: [ConversationReactionMark]
    public var attachments: [ConversationAttachment]
    public var delivery: ConversationDelivery?
    /// Participants mentioned in `text` (UTF-16 ranges).
    public var mentions: [ConversationMention]
    /// Formatting and animated text effects over `text`. Empty when plain.
    public var textRuns: [ConversationTextRun]
    /// Rich link card for the URL that opens or ends `text`, if any.
    public var linkPreview: ConversationLinkPreview?
    /// "Send with effect"; nil for a plain message.
    public var effect: ConversationMessageEffect?
    /// Local only: my Undo Send was refused, so others may still see the
    /// original ("You unsent a message. (!) Not Unsent").
    public var unsendFailed: Bool
    /// A Messages poll carried by this message (`text` holds its question).
    public var poll: ConversationPoll?
    /// Send Later: when the server will send this message. Set only while it
    /// waits (no seq yet); the sent message that replaces it carries none.
    public var scheduledAt: Date?
    /// A group change ("Lawrence named the conversation …") in a message's
    /// place: a centered status row, never a bubble. `senderID` is the actor.
    public var systemEvent: ConversationSystemEvent?
    /// Mine, delivered while the recipient had notifications silenced.
    public var deliveredQuietly: Bool
    /// I tapped Notify Anyway for this quietly delivered message.
    public var notifiedAnyway: Bool

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
        editCount: Int = 0,
        unsentAt: Date? = nil,
        reactions: [ConversationReactionMark] = [],
        attachments: [ConversationAttachment] = [],
        delivery: ConversationDelivery? = nil,
        mentions: [ConversationMention] = [],
        textRuns: [ConversationTextRun] = [],
        linkPreview: ConversationLinkPreview? = nil,
        effect: ConversationMessageEffect? = nil,
        unsendFailed: Bool = false,
        poll: ConversationPoll? = nil,
        scheduledAt: Date? = nil,
        systemEvent: ConversationSystemEvent? = nil,
        deliveredQuietly: Bool = false,
        notifiedAnyway: Bool = false
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
        self.editCount = editedAt == nil ? editCount : max(1, editCount)
        self.unsentAt = unsentAt
        self.reactions = reactions
        self.attachments = attachments
        self.delivery = delivery
        self.mentions = mentions
        self.textRuns = textRuns
        self.linkPreview = linkPreview
        self.effect = effect
        self.unsendFailed = unsendFailed
        self.poll = poll
        self.scheduledAt = scheduledAt
        self.systemEvent = systemEvent
        self.deliveredQuietly = deliveredQuietly
        self.notifiedAnyway = notifiedAnyway
    }

    /// A Send Later message still waiting on the server (or failed to send).
    public var isScheduled: Bool { scheduledAt != nil && seq == nil }

    /// Identity that survives the pending to acknowledged transition, so the
    /// row a sender sees never re-inserts when the server echo arrives.
    public var rowID: String { clientMessageID.map { "c:\($0)" } ?? "s:\(id)" }

    public var isUnsent: Bool { unsentAt != nil }

    /// A status row (group change), not something anyone said.
    public var isSystemEvent: Bool { systemEvent != nil }
    /// Drawn as a centered notice instead of a bubble (unsent, status row).
    /// Renders as a centered system line instead of a bubble: an unsent
    /// message or a system event. It ends the run above it and is not unread.
    public var isNotice: Bool { unsentAt != nil || systemEvent != nil }
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
    public var mentions: [ConversationMention]
    public var textRuns: [ConversationTextRun]
    public var effect: ConversationMessageEffect?
    /// Set when the message creates a poll.
    public var poll: ConversationPollDraft?

    public init(
        clientMessageID: String,
        text: String,
        replyToID: String?,
        attachmentIDs: [String],
        mentions: [ConversationMention] = [],
        textRuns: [ConversationTextRun] = [],
        effect: ConversationMessageEffect? = nil,
        poll: ConversationPollDraft? = nil
    ) {
        self.clientMessageID = clientMessageID
        self.text = text
        self.replyToID = replyToID
        self.attachmentIDs = attachmentIDs
        self.mentions = mentions
        self.textRuns = textRuns
        self.effect = effect
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

/// The shared read marker of a conversation, as the service reports it.
/// `unreadCount` counts messages from others with `seq > lastReadSeq` as of
/// `headSeq`; later arrivals from others add to it.
public struct ConversationReadState: Sendable, Hashable {
    public var lastReadSeq: Int
    public var unreadCount: Int
    public var headSeq: Int

    public init(lastReadSeq: Int, unreadCount: Int, headSeq: Int) {
        self.lastReadSeq = lastReadSeq
        self.unreadCount = unreadCount
        self.headSeq = headSeq
    }
}
