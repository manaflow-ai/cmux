public import CmuxHomeCore

/// The message part a tapback reacts to, and the op it sends. Shared by the
/// Mac and iOS pickers (each host draws its own picker view).
///
/// The op names the message by the owner's id (`TranscriptItem.messageID`),
/// so only a committed, not retracted message with that id gets a picker: a
/// pending send, a refused send or a row without an id gets none (the client
/// never invents ids). Nothing queues, so there is no picker while offline.
public struct HomeReactionTarget: Hashable, Sendable {
    public let item: IdempotencyKey
    public let message: MessageID
    public let conversation: ConversationID
    public let partIndex: Int
    /// The tapbacks I already put on this part (shown selected).
    public let chosen: Set<Reaction.Tapback>

    public init?(item: TranscriptItem, partIndex: Int, conversation: ConversationID, me: ParticipantID, isOnline: Bool) {
        guard isOnline, Self.accepts(item), let message = item.messageID,
              item.parts.indices.contains(partIndex) else { return nil }
        self.item = item.key
        self.message = message
        self.conversation = conversation
        self.partIndex = partIndex
        chosen = Set(item.reactions.compactMap { reaction in
            guard reaction.author == me, reaction.partIndex == partIndex,
                  case .tapback(let tapback) = reaction.kind else { return nil }
            return tapback
        })
    }

    /// Whether a message can take a reaction at all (before a part is known).
    public static func accepts(_ item: TranscriptItem) -> Bool {
        item.messageID != nil && item.delivery == .committed && !item.isRetracted
    }

    /// The op for a choice; nil when I already gave that tapback (the owner
    /// keeps one of each, and there is no op that removes one).
    public func op(_ tapback: Reaction.Tapback) -> HomeOp? {
        guard !chosen.contains(tapback) else { return nil }
        return .addReaction(message: message, conversation: conversation, reaction: .tapback(tapback), partIndex: partIndex)
    }
}

/// The glyph and the localized name of each tapback. The picker buttons and
/// the bubble badges draw the same glyphs; the names are the buttons'
/// accessibility labels.
public struct HomeReactionStyle {
    public init() {}
    /// The picker order.
    public let tapbacks: [Reaction.Tapback] = [.love, .like, .dislike, .laugh, .emphasize, .question]

    public func glyph(_ tapback: Reaction.Tapback) -> String {
        switch tapback {
        case .love: "\u{2764}\u{FE0F}"
        case .like: "\u{1F44D}"
        case .dislike: "\u{1F44E}"
        case .laugh: "\u{1F602}"
        case .emphasize: "\u{203C}\u{FE0F}"
        case .question: "\u{2753}"
        }
    }

    public func glyph(_ kind: Reaction.Kind) -> String {
        switch kind {
        case .emoji(let emoji): emoji
        case .tapback(let tapback): glyph(tapback)
        }
    }

    public func accessibilityName(_ tapback: Reaction.Tapback) -> String {
        switch tapback {
        case .love: String(localized: "tapback.love", defaultValue: "Heart", bundle: .module)
        case .like: String(localized: "tapback.like", defaultValue: "Thumbs Up", bundle: .module)
        case .dislike: String(localized: "tapback.dislike", defaultValue: "Thumbs Down", bundle: .module)
        case .laugh: String(localized: "tapback.laugh", defaultValue: "Ha Ha", bundle: .module)
        case .emphasize: String(localized: "tapback.emphasize", defaultValue: "Exclamation Marks", bundle: .module)
        case .question: String(localized: "tapback.question", defaultValue: "Question Mark", bundle: .module)
        }
    }

    /// The picker's own accessibility label.
    public var pickerLabel: String {
        String(localized: "tapback.picker", defaultValue: "Reactions", bundle: .module)
    }
}

extension HomeController {
    /// The reaction target of a hit bubble, or nil when that message takes no
    /// tapback (pending, refused, retracted, no owner id, or offline).
    public func reactionTarget(for hit: HomeHit, isOnline: Bool) -> HomeReactionTarget? {
        guard let item = items.first(where: { $0.key == hit.item }) else { return nil }
        return HomeReactionTarget(item: item, partIndex: hit.partIndex, conversation: conversation, me: me,
                                  isOnline: isOnline)
    }

    /// The reaction target of a message's accessibility element (a part
    /// row from `accessibilityItems()`), for the hosts' accessibility actions.
    public func reactionTarget(for element: HomeAXItem, isOnline: Bool) -> HomeReactionTarget? {
        guard let key = element.item, element.id.hasPrefix("part:"), let colon = element.id.lastIndex(of: ":"),
              let partIndex = Int(element.id[element.id.index(after: colon)...]),
              let item = items.first(where: { $0.key == key }) else { return nil }
        return HomeReactionTarget(item: item, partIndex: partIndex, conversation: conversation, me: me, isOnline: isOnline)
    }

    /// Emits the tapback's `addReaction` intent through `onIntent`; nil (and
    /// nothing emitted) when I already gave that tapback.
    @discardableResult
    public func react(_ tapback: Reaction.Tapback, to target: HomeReactionTarget) -> HomeIntent? {
        guard target.conversation == conversation, let op = target.op(tapback) else { return nil }
        let intent = HomeIntent(op: op)
        onIntent(intent)
        return intent
    }
}
