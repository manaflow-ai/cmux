import CoreGraphics

/// The thread line that joins an inline reply's quote to the reply, as
/// Messages draws it (`CKReplyLineView`): a 4 pt line in its own column at
/// the transcript's leading edge, whichever side the quote and the reply
/// are on. An end on the trailing side turns into a level arm toward that
/// bubble, at its middle; an end on the leading side meets the bubble
/// itself (the line drops from the quote's bottom edge, or stops just above
/// the reply). So Messages draws `L` for my reply to their message, `⌐` for
/// their reply to mine and `[` for my reply to my own message.
///
/// Measured on an iPhone 17 Pro Max (iOS 27, 3x, 20 pt margins): the line's
/// center runs 16.33 pt in from the margin, its arms end 32 pt further in
/// (`replyLineViewMaxWidth` 36 less the 4 pt width), its corners turn on a
/// circular 19 pt radius at the line's center (21 pt `replyLineBracketRadius` at the
/// outer edge), an arm sits 2.33 pt under its bubble's middle, a line under a
/// quote starts 1.33 pt below the quote's edge and one above a reply stops
/// 7 pt short of it (`replyLineViewVerticalPadding`, round cap).
/// Top-left-origin coordinates, the cell's.
public struct ConversationReplyThread: Equatable, Sendable {
    /// Where the line ends at the quote (top) or at the reply (bottom).
    public enum End: Equatable, Sendable {
        /// A level arm toward a bubble on the trailing side, at this y.
        case arm(y: CGFloat)
        /// The line itself stops at this y, beside a bubble on the leading side.
        case cap(y: CGFloat)

        public var y: CGFloat {
            switch self {
            case let .arm(y), let .cap(y): y
            }
        }
    }

    /// The x the line runs down (its center).
    public var columnX: CGFloat
    public var top: End
    public var bottom: End

    /// `replyLineWidth`.
    public static let lineWidth: CGFloat = 4
    /// From the transcript margin to the line's center.
    public static let columnInset: CGFloat = 49.0 / 3
    /// From the line's center to an arm's end (its center).
    public static let armLength: CGFloat = 32
    /// The corner's radius at the line's center.
    public static let bracketRadius: CGFloat = 19
    /// An arm sits this far under its bubble's middle.
    public static let armDrop: CGFloat = 7.0 / 3
    /// A line under a leading quote starts this far below its bottom edge.
    public static let quoteGap: CGFloat = 4.0 / 3
    /// A line above a leading reply stops this far above it.
    public static let replyGap: CGFloat = 7

    public init(columnX: CGFloat, top: End, bottom: End) {
        self.columnX = columnX
        self.top = top
        self.bottom = bottom
    }

    /// The thread for one transcript row. `quote` and `reply` are the
    /// bubbles' bodies (no tails); `columnX` is the line's center (a group's
    /// avatar column, or `margin + columnInset`); `replyAvatarTop` stops a
    /// line above a group reply's avatar instead of its bubble.
    public static func row(
        quote: CGRect,
        quoteSide: ConversationBubbleGeometry.Side,
        reply: CGRect,
        replySide: ConversationBubbleGeometry.Side,
        columnX: CGFloat,
        replyAvatarTop: CGFloat? = nil
    ) -> ConversationReplyThread {
        let top: End = quoteSide == .trailing
            ? .arm(y: quote.midY + armDrop)
            : .cap(y: quote.maxY + quoteGap)
        let bottom: End = replySide == .trailing
            ? .arm(y: reply.midY + armDrop)
            : .cap(y: min(reply.minY, replyAvatarTop ?? reply.minY) - replyGap)
        return ConversationReplyThread(columnX: columnX, top: top, bottom: bottom)
    }

    /// The corner radius that fits between the two ends.
    public var radius: CGFloat {
        let span = max(0, bottom.y - top.y)
        if case .arm = top, case .arm = bottom { return min(Self.bracketRadius, span / 2) }
        return min(Self.bracketRadius, span)
    }

    public var path: CGPath {
        let x = columnX
        let end = x + Self.armLength
        let r = radius
        let path = CGMutablePath()
        switch top {
        case let .arm(y):
            path.move(to: CGPoint(x: end, y: y))
            path.addLine(to: CGPoint(x: x + r, y: y))
            if r > 0 { path.addArc(tangent1End: CGPoint(x: x, y: y), tangent2End: CGPoint(x: x, y: y + r), radius: r) }
        case let .cap(y):
            path.move(to: CGPoint(x: x, y: y))
        }
        switch bottom {
        case let .arm(y):
            path.addLine(to: CGPoint(x: x, y: max(path.currentPoint.y, y - r)))
            if r > 0 { path.addArc(tangent1End: CGPoint(x: x, y: y), tangent2End: CGPoint(x: x + r, y: y), radius: r) }
            path.addLine(to: CGPoint(x: end, y: y))
        case let .cap(y):
            path.addLine(to: CGPoint(x: x, y: max(path.currentPoint.y, y)))
        }
        return path
    }
}
