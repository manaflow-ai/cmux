import CoreGraphics

/// cmux: the chat column's one layout (the user, 2026-11-09: "from first principles, fix all alignment issues
/// in imessage chat ui", on a Chief reply whose table card, text bubble and name had three left edges).
///
/// Every row of one sender is a frame on two lines:
/// - the **frame edge**: where a bubble, a card, a picture or a drawn row starts (`frameLeading`), and where a
///   wide card and my own bubbles end (`frameTrailing`). A group's incoming frames all start right of the avatar
///   column (`indent`), cards too: the avatar column is a gutter of the whole run, not of its bubbles only.
/// - the **content edge**: ``contentInset`` inside a frame, where its content starts (a bubble's text, the
///   sender's name over it, a card's text, rules and pictures).
///
/// Two widths: a text bubble keeps Messages' reading measure (`Metrics.maxTextWidth`); a card whose content
/// needs room (a table's columns, a pair of screenshots) may run to the trailing edge (``wideWidth``).
/// Corners are concentric: a frame has the bubble's radius, a shape `inset` inside it that radius less the inset
/// (``nestedRadius(inset:)``). Rows of one message are `partGap` apart whatever their kinds.
struct HomeChatColumn: Hashable {
    /// The transcript's layout width.
    var width: CGFloat
    /// How far the sender's frames sit right of the window's leading inset (a group's avatar column, or 0).
    var indent: CGFloat = 0

    /// A frame's edge to its content: a bubble's side padding.
    static let contentInset: CGFloat = Fixture.bubblePadX
    /// A frame's corner radius: a bubble's.
    static let radius: CGFloat = Fixture.bubbleRadius
    /// The gap between two rows of one message (Messages: 3 pt between a group's bubbles).
    static let partGap: CGFloat = 3

    /// Where the sender's incoming frames start (row coordinates).
    var frameLeading: CGFloat { Fixture.leftEdge + indent }
    /// Where a wide card and my own bubbles end.
    var frameTrailing: CGFloat { Metrics(width: width).rightEdge }
    /// Where a frame's content starts.
    var contentLeading: CGFloat { frameLeading + Self.contentInset }
    /// A wide card's width: the frame's leading edge to the trailing edge.
    var wideWidth: CGFloat { max(1, frameTrailing - frameLeading) }

    /// The corner radius of a shape `inset` inside a frame, concentric with the frame's corner; never under 2 pt
    /// (a picture keeps a soft corner).
    static func nestedRadius(inset: CGFloat) -> CGFloat { max(2, radius - inset) }
}
