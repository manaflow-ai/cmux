import Foundation

/// One draft item of an agent's running reply (`conversation-draft`,
/// ephemeral, never stored). `turn` is the idempotency key of the reply the
/// turn will post. A `fresh` item sets its segment's whole text; another
/// item appends to its segment when its `seq` follows the last one; `done`
/// ends the turn's draft.
public struct HomeDraftUpdate: Hashable, Sendable {
    public var conversation: ConversationID
    public var participant: ParticipantID
    public var turn: IdempotencyKey
    public var segment: UInt64
    public var seq: UInt64
    /// `talk` text shows; a `thought` never does.
    public var isTalk: Bool
    public var text: String
    public var fresh: Bool
    public var done: Bool

    public init(conversation: ConversationID, participant: ParticipantID, turn: IdempotencyKey, segment: UInt64,
                seq: UInt64, isTalk: Bool, text: String, fresh: Bool, done: Bool) {
        self.conversation = conversation
        self.participant = participant
        self.turn = turn
        self.segment = segment
        self.seq = seq
        self.isTalk = isTalk
        self.text = text
        self.fresh = fresh
        self.done = done
    }
}

/// The running reply of one conversation's agent turn, as its drafts say.
public struct HomeTurnDraft: Hashable, Sendable {
    public var participant: ParticipantID
    public var turn: IdempotencyKey
    /// Talk text by segment (a new segment starts after each tool call).
    var segments: [UInt64: String] = [:]
    var lastSeq: UInt64 = 0
    /// A seq was missed: nothing new shows until the next `fresh` item.
    var gap = false

    public init(participant: ParticipantID, turn: IdempotencyKey) {
        self.participant = participant
        self.turn = turn
    }

    /// The reply so far: the segments in order, joined by a blank line.
    public var text: String {
        segments.keys.sorted().compactMap { segments[$0] }.joined(separator: "\n\n")
    }

    mutating func apply(_ update: HomeDraftUpdate) {
        let follows = lastSeq != 0 && update.seq == lastSeq + 1
        lastSeq = max(lastSeq, update.seq)
        guard update.isTalk else { return }
        if update.fresh {
            gap = false
            segments[update.segment] = update.text
        } else if gap || !follows {
            gap = true
        } else {
            segments[update.segment, default: ""] += update.text
        }
    }
}

/// HomeStore's live drafts: at most one running turn per conversation. A turn
/// ends with its `done` item, its posted reply (same author and key), its
/// author's typing off, or a new turn that replaces it; a draft of an ended
/// turn that arrives late is dropped, so its bubble never comes back.
struct HomeDraftBook {
    private(set) var live: [ConversationID: HomeTurnDraft] = [:]
    /// Turns that ended, newest last (bounded).
    private var ended: [IdempotencyKey] = []
    static let endedLimit = 256

    /// True when the visible draft changed.
    mutating func apply(_ update: HomeDraftUpdate) -> Bool {
        guard !ended.contains(update.turn) else { return false }
        if update.done {
            return end(update.conversation) { $0.turn == update.turn }
        }
        let before = live[update.conversation]
        // A new turn replaces the live one: the old turn ended, so its late items stay dropped.
        if let before, before.turn != update.turn { remember(before.turn) }
        var draft = before.flatMap { $0.turn == update.turn ? $0 : nil }
            ?? HomeTurnDraft(participant: update.participant, turn: update.turn)
        draft.apply(update)
        live[update.conversation] = draft
        return before?.text != draft.text || before?.turn != draft.turn
    }

    /// A message was committed: its draft (same author and key) ends.
    mutating func posted(_ message: Message) -> Bool {
        remember(message.clientMessageID)
        return end(message.conversation) { $0.turn == message.clientMessageID && $0.participant == message.author }
    }

    /// The participant stopped typing: its turn ended.
    mutating func typingOff(_ conversation: ConversationID, _ participant: ParticipantID) -> Bool {
        end(conversation) { $0.participant == participant }
    }

    private mutating func end(_ conversation: ConversationID, _ matches: (HomeTurnDraft) -> Bool) -> Bool {
        guard let draft = live[conversation], matches(draft) else { return false }
        live[conversation] = nil
        remember(draft.turn)
        return true
    }

    private mutating func remember(_ turn: IdempotencyKey) {
        guard !ended.contains(turn) else { return }
        ended.append(turn)
        if ended.count > Self.endedLimit { ended.removeFirst(ended.count - Self.endedLimit) }
    }
}
