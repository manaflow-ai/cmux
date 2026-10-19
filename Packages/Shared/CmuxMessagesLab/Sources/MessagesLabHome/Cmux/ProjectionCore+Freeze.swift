import CmuxHomeCore
import Foundation

/// A running reply whose shown text my send froze in place: each frozen piece is a
/// bubble of its own above the send that froze it; the reply's later text streams
/// (and its posted message shows) below, as the rest after `prefix`.
struct FrozenReply: Equatable {
    struct Piece: Equatable {
        /// The piece's transcript key: the reply's key and its place ("<turn>#1").
        var key: IdempotencyKey
        var text: String
        /// My send it stays above.
        var before: IdempotencyKey
        var createdAt: Date
    }

    var author: ParticipantID
    var pieces: [Piece] = []
    /// The reply's whole text when the last piece froze: the posted reply must start with it.
    var prefix = ""
}

/// Send order while the Chief's reply streams (cx home-send-order): the streaming bubble
/// is the newest row (MessagesLab ask 11 keeps it last), so a message I send while it
/// shows text would land above text that was already on screen. Instead the shown text
/// becomes a bubble in place (the stream ends into it, `.streamEnd(replacedBy:)`: no row
/// moves), my send goes below it, and what the reply says next streams below my send.
/// The posted reply then shows as that rest only, at its own place, so nothing jumps.
/// The pieces live in this view only (other clients and a reopened Home show the
/// posted reply whole, in the owner's order).
extension ProjectionCore {
    /// Freezes the shown stream before my send `key` goes out; the actions end the stream into its piece.
    mutating func freezeStream(before key: IdempotencyKey, in state: AppState) -> [Action] {
        guard state.atNewest, let live = shownStream, !live.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var reply = frozen[live.turn] ?? FrozenReply(author: live.author)
        let piece = FrozenReply.Piece(key: IdempotencyKey("\(live.turn.rawValue)#\(reply.pieces.count + 1)"),
                                      text: live.text.trimmingCharacters(in: .whitespacesAndNewlines), before: key, createdAt: Date())
        reply.pieces.append(piece)
        reply.prefix = live.full
        frozen[live.turn] = reply
        let item = Self.item(piece, author: reply.author)
        shownStream = nil
        insertShown(item)
        return [.streamEnd(Self.streamID(live.turn), replacedBy: finalMessage(item))]
    }

    /// What to stream of the reply `turn` whose whole text is `full`: all of it, or the part after
    /// its frozen prefix; nil when the reply no longer starts with that prefix (the pieces go).
    func streamText(turn: IdempotencyKey, full: String) -> String? {
        guard let reply = frozen[turn] else { return full }
        guard full.hasPrefix(reply.prefix) else { return full }
        return String(full.dropFirst(reply.prefix.count))
    }

    /// HomeStore's items as this view shows them: each frozen piece above the send that froze it,
    /// and a posted frozen reply as its rest (none when nothing came after the pieces). A posted
    /// reply that does not start with its frozen text drops the pieces (one rebuild, owner order).
    mutating func arrange(_ items: [TranscriptItem]) -> [TranscriptItem] {
        guard !frozen.isEmpty else { return items }
        var out = items
        for (turn, reply) in frozen.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            if let i = out.firstIndex(where: { $0.key == turn }), let posted = out[checked: i] {
                guard case let .text(full, mentions)? = posted.parts.first, posted.parts.count == 1, mentions.isEmpty,
                      full.hasPrefix(reply.prefix) else {
                    frozen[turn] = nil
                    continue
                }
                let rest = String(full.dropFirst(reply.prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if rest.isEmpty {
                    out.remove(at: i)
                } else {
                    var shortened = posted
                    shortened.parts = [.text(rest)]
                    out[i] = shortened
                }
            }
            for piece in reply.pieces {
                let item = Self.item(piece, author: reply.author)
                if let at = out.firstIndex(where: { $0.key == piece.before }) { out.insert(item, at: at) } else { out.append(item) }
            }
        }
        return out
    }

    private static func item(_ piece: FrozenReply.Piece, author: ParticipantID) -> TranscriptItem {
        TranscriptItem(key: piece.key, seq: nil, author: author, parts: [.text(piece.text)], createdAt: piece.createdAt, delivery: .committed)
    }
}
