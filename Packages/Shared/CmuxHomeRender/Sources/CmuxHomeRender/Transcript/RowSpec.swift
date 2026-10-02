import CoreGraphics
import Foundation

/// One row of the transcript, derived from CmuxHomeCore `TranscriptItem`s,
/// never stored. A spec does not depend on the viewport width except through
/// the wrapped text it carries, so a resize that keeps a row's wrap keeps its
/// spec, and the row keeps its bitmap.
struct RowSpec: Hashable {
    var key: String
    var kind: Kind
    /// Space above the content.
    var gap: CGFloat
    /// Content height.
    var height: CGFloat

    var total: CGFloat { gap + height }

    enum Kind: Hashable {
        /// Day and time above a message that starts a new block.
        case separator(bold: String, rest: String)
        /// A retracted message.
        case unsent(outgoing: Bool)
        case part(PartRow)
        /// "Not Delivered" under a send the owner refused.
        case failedLabel(String)
        /// "Read" or "Delivered" under my latest send.
        case receipt(String)
        case typing
    }

    /// Cheap hash: key and geometry. Equality still compares everything, so
    /// specs that differ only in content are told apart by `==`.
    func hash(into h: inout Hasher) {
        h.combine(key)
        h.combine(height)
        h.combine(gap)
    }

    var partRow: PartRow? {
        if case .part(let p) = kind { return p }
        return nil
    }
}

/// A text bubble. Every CmuxHomeCore message part renders as one: text with
/// its mentions in bold; work and approval parts as their plain text.
struct PartRow: Hashable {
    var outgoing: Bool
    var tail: Bool
    var failed: Bool
    var reactions: [ReactionBadge]
    /// Bubble size (text plus padding).
    var size: CGSize
    var text: TextLayout

    /// The drawn body: lines after a hard newline are 15.5 pt apart in a sent
    /// bubble, so its body is shorter than its 16 pt-per-line slot and sits
    /// at the slot top.
    var bodySize: CGSize {
        guard outgoing else { return size }
        return CGSize(width: size.width,
                      height: min(size.height, text.textHeight(hard: Style.hardBreakAdvance) + 2 * Style.bubblePadY))
    }
}

/// One tapback or emoji on a bubble.
struct ReactionBadge: Hashable {
    var glyph: String
    /// The signed-in user reacted (drawn in the outgoing colour).
    var mine: Bool
}
