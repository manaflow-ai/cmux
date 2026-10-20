import CmuxHomeCore
import Foundation

/// The agent's running reply on screen: MessagesLab's streaming bubble (ask 11,
/// `.streamBegin` / `.streamSet` / `.streamEnd`), keyed by the reply's turn key
/// (its `client_msg_id`), so the posted reply takes the bubble's place in place.
struct ShownStream: Equatable {
    var turn: IdempotencyKey
    var author: ParticipantID
    var text: String
    /// The last `.streamSet` seq (MessagesLab ignores a seq not above it).
    var seq = 0
}

/// HomeStore's running reply (HomeStore.live, or a `conversation-draft` from an
/// older owner) through MessagesLab's streaming bubble (cx-kmak2, pin d7b2df6):
/// the first text begins the stream (the typing dots turn into the bubble), each
/// change sets the whole text with the final message's parts (Markdown renders the
/// whole text), the posted reply (same key) ends it with `replacedBy:` (MessagesLab
/// gives it the bubble's rows and cells: nothing moves), and a reply that ends
/// without a message ends it with `replacedBy: nil` (it leaves as the typing
/// indicator). The author's typing dots follow HomeStore's typing (core.typing),
/// not the stream: an extra `.typing(false)` would blink them when HomeStore still
/// reports typing. Limits: the stream bubble has no thread root and no mentions
/// (a Chief's top-level reply has neither), so such a reply moves once in place.
extension ProjectionCore {
    /// True when `stream(_:state:)` would act.
    func streamDiffers(_ want: HomeTurnDraft?) -> Bool {
        let visible = want.flatMap { Self.visibleText($0) == nil ? nil : $0 }
        return visible?.turn != shownStream?.turn || visible.map(\.text) != shownStream.map(\.text)
    }

    /// The turn whose posted reply HomeDiff must leave to the stream's end (no `.receive`).
    var streamingTurn: IdempotencyKey? { shownStream?.turn }

    mutating func stream(_ want: HomeTurnDraft?, state: AppState) -> [Action] {
        var actions: [Action] = []
        if let live = shownStream, want?.turn != live.turn || shown.contains(where: { $0.key == live.turn }) {
            shownStream = nil
            let final = shown.first { $0.key == live.turn }.map(finalMessage)
            // The author's typing then follows HomeStore (core.typing): a final message ends it in MessagesLab.
            actions.append(.streamEnd(Self.streamID(live.turn), replacedBy: final))
        }
        // A reply already posted (a page brought it first) needs no stream.
        guard let want, let text = Self.visibleText(want), !shown.contains(where: { $0.key == want.turn }) else {
            return actions
        }
        let bubble = bubble(want, text: text)
        if var live = shownStream {
            guard text != live.text else { return actions }
            live.text = text
            live.seq += 1
            actions.append(.streamSet(Self.streamID(want.turn), text: text, parts: bubble.parts, seq: live.seq))
            shownStream = live
            return actions
        }
        // An older window shows: the reply comes as a message at the newest.
        guard state.atNewest else { return actions }
        shownStream = ShownStream(turn: want.turn, author: want.participant, text: text, seq: 1)
        actions.append(.streamBegin(Self.streamID(want.turn), sender: want.participant.rawValue, format: bubble.format))
        actions.append(.streamSet(Self.streamID(want.turn), text: text, parts: bubble.parts, seq: 1))
        return actions
    }

    /// The reply's whole text so far, nil while it is only whitespace. Always the whole reply: a send
    /// while it streams never cuts it (the bubble stays one, below the send, in the owner's order).
    private static func visibleText(_ draft: HomeTurnDraft) -> String? {
        let text = draft.text
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    static func streamID(_ turn: IdempotencyKey) -> StreamID { turn.rawValue }

    /// The posted reply as the transcript shows it (HomeMapping.id: no alias).
    private func finalMessage(_ item: TranscriptItem) -> Message {
        let roots = HomeMapping.roots(in: shown, aliases: aliases, summary: summary, media: media, links: links)
        return HomeMapping.message(item, aliases: aliases, me: me, summary: summary, media: media, links: links, roots: roots)
    }

    /// The message the posted reply will be: the same mapping (parts, format) as a committed agent message.
    private func bubble(_ draft: HomeTurnDraft, text: String) -> Message {
        let item = TranscriptItem(key: draft.turn, seq: nil, author: draft.participant, parts: [.text(text)],
                                  createdAt: Date(), delivery: .committed)
        return HomeMapping.message(item, aliases: aliases, me: me, summary: summary, media: media, links: links)
    }
}
