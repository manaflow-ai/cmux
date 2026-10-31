import CmuxHomeCore
import Foundation

/// One running reply on screen: MessagesLab's streaming bubble (ask 11,
/// `.streamBegin` / `.streamSet` / `.streamEnd`), keyed by the reply's turn key
/// (its `client_msg_id`), so the posted reply takes the bubble's place in place.
struct ShownStream: Equatable {
    var turn: IdempotencyKey
    var author: ParticipantID
    var text: String
    /// The last `.streamSet` seq (MessagesLab ignores a seq not above it).
    var seq = 0
}

/// HomeStore's running replies (``HomeTimeline/streams``: Chief live runs and
/// `conversation-draft` replies from older owners) through MessagesLab's streaming
/// bubbles (plans/cmux-next/home-chat-pipeline-DESIGN.md section 2.3). Each reply is
/// one bubble, in the order its turn began, below every message: its first text
/// begins it, each change sets its whole text with the final message's parts
/// (Markdown renders the whole text), its posted reply (same key) ends it with
/// `replacedBy:` (MessagesLab gives it the bubble's rows and cells: nothing moves),
/// and a reply that ends without a message ends it with `replacedBy: nil`. Several
/// replies can run at once (two Chiefs in a group; a new turn while the last
/// reply is on its way). The authors' typing dots follow HomeStore's typing
/// (core.typing), not the streams. Limits: a stream bubble has no thread root
/// and no mentions (a Chief's top-level reply has neither), so such a reply moves
/// once in place.
extension ProjectionCore {
    /// The rows `streams(_:state:)` would show, in order.
    private func visible(_ want: [HomeStreamRow]) -> [HomeStreamRow] {
        // Whole messages (the default, user Oct 20): no stream bubble ever shows; each running
        // reply is its author's typing dots (`replyTypists`) and each message comes whole (`.receive`).
        guard replies == .streaming else { return [] }
        // The first non-whitespace character ends the scan (trimming copied the whole reply every token).
        return want.filter { row in row.text.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) } && !shown.contains { $0.key == row.turn } }
    }

    /// True when `streams(_:state:)` would act.
    func streamsDiffer(_ want: [HomeStreamRow]) -> Bool {
        let rows = visible(want)
        return rows.map(\.turn) != shownStreams.map(\.turn) || rows.map(\.text) != shownStreams.map(\.text)
    }

    /// The turns whose posted replies HomeDiff must leave to their streams' ends (no `.receive`).
    var streamingTurns: Set<IdempotencyKey> { Set(shownStreams.map(\.turn)) }

    /// The actions from the streams on screen to `want` (in begin order).
    mutating func streams(_ want: [HomeStreamRow], state: AppState) -> [Action] {
        var actions: [Action] = []
        let rows = visible(want)
        let wanted = Set(rows.map(\.turn))
        // Streams that ended: their posted reply takes their place, or they leave.
        for live in shownStreams where !wanted.contains(live.turn) {
            let final = shown.first { $0.key == live.turn }.map(finalMessage)
            actions.append(.streamEnd(Self.streamID(live.turn), replacedBy: final))
        }
        shownStreams.removeAll { !wanted.contains($0.turn) }
        streamMappers.keep(only: wanted)
        // The streams that stay must keep their order (new ones go below them); a reply that began
        // earlier than one on screen (a snapshot after a join) restarts the bubbles in order.
        let staying = rows.map(\.turn).filter { turn in shownStreams.contains { $0.turn == turn } }
        if staying != shownStreams.map(\.turn) {
            for live in shownStreams { actions.append(.streamEnd(Self.streamID(live.turn), replacedBy: nil)) }
            shownStreams.removeAll()
        }
        for row in rows {
            let bubble = bubble(row)
            if let i = shownStreams.firstIndex(where: { $0.turn == row.turn }) {
                guard let shown = shownStreams[checked: i], shown.text != row.text else { continue }
                let seq = shown.seq + 1
                shownStreams.update(at: i) { $0.text = row.text; $0.seq = seq }
                actions.append(.streamSet(Self.streamID(row.turn), text: row.text, parts: bubble.parts, seq: seq))
                continue
            }
            // An older window shows: the reply comes as a message at the newest.
            guard state.atNewest else { continue }
            shownStreams.append(ShownStream(turn: row.turn, author: row.author, text: row.text, seq: 1))
            actions.append(.streamBegin(Self.streamID(row.turn), sender: row.author.rawValue, format: bubble.format))
            actions.append(.streamSet(Self.streamID(row.turn), text: row.text, parts: bubble.parts, seq: 1))
        }
        return actions
    }

    /// The authors of running replies whose dots must show (whole messages): HomeStore's live runs
    /// already count as typing, an older owner's `conversation-draft` may not. A reply already posted is not running.
    func replyTypists(_ want: [HomeStreamRow]) -> Set<ParticipantID> {
        guard replies == .wholeMessages else { return [] }
        return Set(want.filter { row in !shown.contains { $0.key == row.turn } }.map(\.author))
    }

    static func streamID(_ turn: IdempotencyKey) -> StreamID { turn.rawValue }

    /// The posted reply as the transcript shows it (HomeMapping.id: no alias).
    private func finalMessage(_ item: TranscriptItem) -> Message {
        let roots = HomeMapping.roots(in: shown, aliases: aliases, summary: summary, media: media, links: links)
        return HomeMapping.message(item, aliases: aliases, me: me, summary: summary, media: media, links: links, roots: roots)
    }

    /// The message the posted reply will be: the same mapping (parts, format) as a committed agent message.
    private func bubble(_ row: HomeStreamRow) -> Message {
        let item = TranscriptItem(key: row.turn, seq: nil, author: row.author, parts: [.text(row.text)],
                                  createdAt: Date(), delivery: .committed)
        guard HomeMapping.isAgent(row.author, summary) else {
            return HomeMapping.message(item, aliases: aliases, me: me, summary: summary, media: media, links: links)
        }
        // An agent's reply: the same parts as HomeMapping.parts(markdown: true), at the token's cost
        // (HomeStreamMapper keeps the reply's rendered lines between tokens).
        var bare = item
        bare.parts = []
        var message = HomeMapping.message(bare, aliases: aliases, me: me, summary: summary, media: media, links: links)
        message.parts = streamMappers.mapper(row.turn).parts(row.text, links: links)
        message.format = .markdown
        return message
    }
}
