public import Foundation

/// One conversation's whole transcript as a view draws it, in display order
/// (plans/cmux-next/home-chat-pipeline-DESIGN.md section 2.1).
///
/// The order is total and uses no clock:
/// 1. committed messages by the owner's `seq`;
/// 2. my pending sends, in the order I made them;
/// 3. every running reply, in the order its turn began.
///
/// A running reply's id is its turn key, the `client_msg_id` its posted message carries, so a
/// view hands its bubble to the message in place; once that message is in ``items`` the
/// stream is gone from ``streams``.
///
/// ```swift
/// let timeline = store.timeline(for: conversation)
/// for row in timeline.items { draw(row) }
/// for stream in timeline.streams { drawStreaming(stream) }
/// ```
public struct HomeTimeline: Hashable, Sendable {
    /// Committed messages by seq, then my pending sends in send order.
    public var items: [TranscriptItem]
    /// The running replies after every item, in the order their turns began.
    public var streams: [HomeStreamRow]

    /// Makes a timeline; a stream whose posted message is already among `items` is dropped.
    ///
    /// - Parameters:
    ///   - items: the transcript rows, already in order (``HomeStore/transcript(for:)``).
    ///   - streams: the running replies in begin order.
    public init(items: [TranscriptItem], streams: [HomeStreamRow]) {
        self.items = items
        if streams.isEmpty {
            self.streams = []
        } else {
            let keys = Set(items.map(\.key))
            self.streams = streams.filter { !keys.contains($0.turn) }
        }
    }

    /// Every row id in display order: the item keys, then the stream turn keys.
    public var ids: [IdempotencyKey] { items.map(\.key) + streams.map(\.turn) }
}

/// One running reply: an agent's message being written, one bubble from its first text to its post.
public struct HomeStreamRow: Hashable, Sendable, Identifiable {
    /// The reply's key, fixed when its turn began: its posted message carries it.
    public var turn: IdempotencyKey
    /// Who writes it.
    public var author: ParticipantID
    /// The reply so far (never only white space).
    public var text: String

    /// Makes a row.
    ///
    /// - Parameters:
    ///   - turn: the key the posted reply will carry.
    ///   - author: the agent that writes it.
    ///   - text: its text so far.
    public init(turn: IdempotencyKey, author: ParticipantID, text: String) {
        self.turn = turn
        self.author = author
        self.text = text
    }

    /// The turn key.
    public var id: IdempotencyKey { turn }

    /// The row as a running reply for views that grow a ``HomeTurnDraft``.
    public var turnDraft: HomeTurnDraft {
        var draft = HomeTurnDraft(participant: author, turn: turn)
        draft.segments[0] = text
        return draft
    }
}
